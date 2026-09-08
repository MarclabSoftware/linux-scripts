#!/usr/bin/env bash

# Vaultwarden Restore Utility
#
# Verifies and restores a selected snapshot with an atomic directory swap and
# automatic rollback when container startup or health verification fails.
# Settings are shared with the receiver through vaultwarden_recovery.env.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/vaultwarden_recovery.env"

die() {
    printf 'vaultwarden_restore.sh: %s\n' "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${VAULTWARDEN_RECOVERY_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] || die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) || die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
    cat <<'EOF'
Usage: vaultwarden_restore.sh [--check-config] [--verify] [SNAPSHOT_ID|latest]

  --check-config  Validate configuration without accessing snapshots or Docker.
  --verify  Fully stage and validate the snapshot without stopping Vaultwarden.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

load_environment

: "${VAULTWARDEN_BACKUP_ROOT:?VAULTWARDEN_BACKUP_ROOT is required}"
: "${VAULTWARDEN_STACK_DIR:?VAULTWARDEN_STACK_DIR is required}"

readonly BACKUP_ROOT="${VAULTWARDEN_BACKUP_ROOT}"
readonly SNAPSHOTS_DIR="${BACKUP_ROOT}/snapshots"
readonly STACK_DIR="${VAULTWARDEN_STACK_DIR}"
DATA_DIR="${VAULTWARDEN_DATA_DIR:-${STACK_DIR}/mnt/data}"
readonly COMPOSE_FILE="${VAULTWARDEN_COMPOSE_FILE:-${STACK_DIR}/compose.yaml}"
readonly SERVICE_NAME="${VAULTWARDEN_SERVICE_NAME:-vaultwarden}"
readonly HEALTH_TIMEOUT_SECONDS="${VAULTWARDEN_HEALTH_TIMEOUT_SECONDS:-60}"

[[ "${BACKUP_ROOT}" == /* && "${STACK_DIR}" == /* && "${DATA_DIR}" == /* && "${COMPOSE_FILE}" == /* ]] ||
    die "backup, stack, data and compose paths must be absolute"
[[ "${SERVICE_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "VAULTWARDEN_SERVICE_NAME is invalid"
[[ "${HEALTH_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] ||
    die "VAULTWARDEN_HEALTH_TIMEOUT_SECONDS must be a positive integer"

if [[ "${1:-}" == "--check-config" ]]; then
    [[ $# -eq 1 ]] || die "--check-config does not accept additional arguments"
    printf 'vaultwarden_restore.sh configuration is valid\n'
    exit 0
fi

for command_name in flock realpath sha256sum sqlite3 stat; do
    require_command "${command_name}"
done

DATA_DIR="$(realpath -m -- "${DATA_DIR}")"
readonly DATA_DIR
[[ "${DATA_DIR}" != / ]] || die "the filesystem root cannot be a data directory"
[[ ! -e "${DATA_DIR}" || -d "${DATA_DIR}" ]] || die "data path is not a directory"
readonly DATA_PARENT="${DATA_DIR%/*}"
readonly DATA_NAME="${DATA_DIR##*/}"
[[ -d "${DATA_PARENT:-/}" ]] || die "data parent directory does not exist"

# Keep the selected snapshot alive while receiver retention is running.
# Acquire locks in the same order as the receiver: receive, then standby.
exec 8>"${BACKUP_ROOT}/receive.lock"
flock -n 8 || die "another snapshot operation is already running"

verify_snapshot() {
    local source="${1}"
    local database_check

    [[ -f "${source}/SHA256SUMS" && -f "${source}/data/db.sqlite3" ]] ||
        die "snapshot files are incomplete"
    (
        cd -- "${source}"
        sha256sum --check --strict SHA256SUMS >/dev/null
    ) || die "snapshot checksum verification failed"
    database_check="$(sqlite3 "${source}/data/db.sqlite3" 'PRAGMA integrity_check;')"
    [[ "${database_check}" == "ok" ]] || die "snapshot failed SQLite integrity_check"
}

stage_snapshot() {
    local source="${1}"
    local destination="${2}"
    local database_check

    cp -a -- "${source}/data/." "${destination}/" || return
    rm -f -- "${destination}/db.sqlite3-wal" "${destination}/db.sqlite3-shm" || return
    database_check="$(sqlite3 "${destination}/db.sqlite3" 'PRAGMA integrity_check;')" || return
    [[ "${database_check}" == "ok" ]] || die "staged database failed SQLite integrity_check"
}

verify_only=false
case "${1:-}" in
    --verify)
        verify_only=true
        shift
        ;;
    *) ;;
esac
[[ $# -le 1 ]] || die "too many arguments"
requested="${1:-latest}"

if [[ "${requested}" == "latest" ]]; then
    snapshot="$(readlink -f "${BACKUP_ROOT}/latest")"
else
    [[ "${requested}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "snapshot ID is invalid"
    snapshot="${SNAPSHOTS_DIR}/${requested}"
fi
case "${snapshot}" in
    "${SNAPSHOTS_DIR}"/*) ;;
    *) die "snapshot resolves outside the snapshots directory" ;;
esac
[[ -d "${snapshot}" ]] || die "snapshot does not exist: ${requested}"
verify_snapshot "${snapshot}"

snapshot_id="$(basename -- "${snapshot}")"
if "${verify_only}"; then
    verify_stage="$(mktemp -d "${DATA_PARENT}/.${DATA_NAME}.verify.XXXXXX")"
    trap 'rm -rf -- "${verify_stage}"' EXIT
    stage_snapshot "${snapshot}" "${verify_stage}"
    printf 'vaultwarden snapshot verified: %s\n' "${snapshot_id}"
    exit 0
fi

[[ -f "${COMPOSE_FILE}" ]] || die "compose file does not exist: ${COMPOSE_FILE}"
require_command docker
exec 9>"${BACKUP_ROOT}/standby.lock"
flock -n 9 || die "another restore or standby refresh is already running"

# Every rename stays on the data filesystem, including custom DATA_DIR paths.
transaction_dir="$(mktemp -d "${DATA_PARENT}/.${DATA_NAME}.restore.XXXXXX")"
stage="${transaction_dir}/candidate"
rollback="${transaction_dir}/previous"
failed="${transaction_dir}/failed"
transaction_started=false
committed=false
previous_running=false

run_compose() {
    docker compose --project-directory "${STACK_DIR}" -f "${COMPOSE_FILE}" "$@"
}

# Return failure to the transaction owner; callers may deliberately test status.
wait_for_service() {
    local container status attempt

    # shellcheck disable=SC2310
    container="$(run_compose ps -q "${SERVICE_NAME}")" || return
    [[ -n "${container}" && "${container}" != *$'\n'* ]] || return 1
    for ((attempt = 1; attempt <= HEALTH_TIMEOUT_SECONDS; attempt++)); do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else if .State.Running}}running{{else}}stopped{{end}}' "${container}")" || return
        case "${status}" in
            healthy | running) return 0 ;;
            unhealthy | stopped) return 1 ;;
            *) ;;
        esac
        sleep 1 || return
    done
    return 1
}

# Every operation in the recovery path propagates failure explicitly.
restore_previous() {
    # Directory presence records successful atomic moves even if a signal
    # arrives before the next shell assignment can run.
    if [[ -d "${rollback}" || ! -d "${stage}" ]]; then
        # shellcheck disable=SC2310
        run_compose stop "${SERVICE_NAME}" || return
        if [[ ! -d "${stage}" && -e "${DATA_DIR}" ]]; then
            mv -T -- "${DATA_DIR}" "${failed}" || return
        fi
        if [[ -d "${rollback}" ]]; then
            mv -T -- "${rollback}" "${DATA_DIR}" || return
        fi
    fi
    if [[ "${previous_running}" == true ]]; then
        # shellcheck disable=SC2310
        run_compose up -d "${SERVICE_NAME}" || return
        # shellcheck disable=SC2310
        wait_for_service || return
    fi
    return 0
}

# Recovery failure preserves the transaction rather than removing its evidence.
finish_restore() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ "${transaction_started}" == true && "${committed}" != true ]]; then
        # The original failure must stay visible even when rollback succeeds.
        status=1
        # shellcheck disable=SC2310
        if restore_previous; then
            printf 'restore failed; previous data and service state restored\n' >&2
        else
            printf 'restore rollback failed; recovery files retained at %s\n' "${transaction_dir}" >&2
            exit 1
        fi
    fi
    rm -rf -- "${stage}" || status=1
    if [[ -d "${rollback}" || -d "${failed}" ]]; then
        printf 'recovery files retained at %s\n' "${transaction_dir}" >&2
    else
        rmdir -- "${transaction_dir}" || status=1
    fi
    exit "${status}"
}
trap finish_restore EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -- "${stage}"
stage_snapshot "${snapshot}" "${stage}"
# run_compose is a transparent command wrapper; inspect its exit status.
# shellcheck disable=SC2310
previous_containers="$(run_compose ps --status running -q "${SERVICE_NAME}")" ||
    die "cannot determine the previous service state"
[[ -z "${previous_containers}" ]] || previous_running=true

transaction_started=true
run_compose stop "${SERVICE_NAME}"
[[ ! -e "${DATA_DIR}" ]] || mv -T -- "${DATA_DIR}" "${rollback}"
mv -T -- "${stage}" "${DATA_DIR}"
run_compose up -d "${SERVICE_NAME}"
# wait_for_service checks every operation without relying on errexit.
# shellcheck disable=SC2310
wait_for_service || die "restored service failed startup or health verification"
committed=true
printf 'vaultwarden restored: %s\n' "${snapshot_id}"
