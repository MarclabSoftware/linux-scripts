#!/usr/bin/env bash

# Vaultwarden Restore Utility
# Version: 2.0.0
# Updated: 2026-07-29
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
readonly DATA_DIR="${VAULTWARDEN_DATA_DIR:-${STACK_DIR}/mnt/data}"
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

for command_name in docker flock sha256sum sqlite3 stat; do
    require_command "${command_name}"
done

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

    cp -a -- "${source}/data/." "${destination}/"
    rm -f -- "${destination}/db.sqlite3-wal" "${destination}/db.sqlite3-shm"
    database_check="$(sqlite3 "${destination}/db.sqlite3" 'PRAGMA integrity_check;')"
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
    verify_stage="$(mktemp -d "${STACK_DIR}/mnt/.verify-restore.XXXXXX")"
    trap 'rm -rf -- "${verify_stage}"' EXIT
    stage_snapshot "${snapshot}" "${verify_stage}"
    printf 'vaultwarden snapshot verified: %s\n' "${snapshot_id}"
    exit 0
fi

[[ -f "${COMPOSE_FILE}" ]] || die "compose file does not exist: ${COMPOSE_FILE}"
exec 9>"${BACKUP_ROOT}/standby.lock"
flock -n 9 || die "another restore or standby refresh is already running"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
stage="$(mktemp -d "${STACK_DIR}/mnt/.restore.XXXXXX")"
rollback="${STACK_DIR}/mnt/data.rollback-${stamp}"
failed="${STACK_DIR}/mnt/data.failed-${stamp}"
trap '[[ ! -d "${stage}" ]] || rm -rf -- "${stage}"' EXIT

stage_snapshot "${snapshot}" "${stage}"

docker compose --project-directory "${STACK_DIR}" -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}"
[[ ! -e "${DATA_DIR}" ]] || mv -- "${DATA_DIR}" "${rollback}"
mv -- "${stage}" "${DATA_DIR}"

restore_previous() {
    docker compose --project-directory "${STACK_DIR}" -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}" || true
    [[ ! -e "${DATA_DIR}" ]] || mv -- "${DATA_DIR}" "${failed}"
    if [[ -d "${rollback}" ]]; then
        mv -- "${rollback}" "${DATA_DIR}"
        docker compose --project-directory "${STACK_DIR}" -f "${COMPOSE_FILE}" up -d "${SERVICE_NAME}" || true
    fi
}

if ! docker compose --project-directory "${STACK_DIR}" -f "${COMPOSE_FILE}" up -d "${SERVICE_NAME}"; then
    restore_previous
    die "restore failed; previous data was restored"
fi

container="$(docker compose --project-directory "${STACK_DIR}" -f "${COMPOSE_FILE}" ps -q "${SERVICE_NAME}")"
if [[ -z "${container}" ]]; then
    restore_previous
    die "restore failed; Vaultwarden container was not found"
fi

for ((attempt = 1; attempt <= HEALTH_TIMEOUT_SECONDS; attempt++)); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else if .State.Running}}running{{else}}stopped{{end}}' "${container}")"
    case "${status}" in
        healthy | running)
            printf 'vaultwarden restored: %s\n' "${snapshot_id}"
            exit 0
            ;;
        unhealthy | stopped) break ;;
        *) ;;
    esac
    sleep 1
done

restore_previous
die "restore failed health verification; previous data was restored"
