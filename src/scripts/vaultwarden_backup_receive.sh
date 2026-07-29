#!/usr/bin/env bash

# Vaultwarden Backup Receiver
# Version: 2.0.0
# Updated: 2026-07-29
#
# Intended as an authorized_keys forced command. It accepts one archive on
# standard input, validates paths, checksums and SQLite integrity, then
# publishes the snapshot atomically. Receiver and restore settings share the
# adjacent vaultwarden_recovery.env sidecar.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/vaultwarden_recovery.env"

die() {
    printf 'vaultwarden_backup_receive.sh: %s\n' "$*" >&2
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

check_config=false
case "${1:-}" in
    --help | -h)
        printf 'Usage: vaultwarden_backup_receive.sh [--check-config]\n'
        exit 0
        ;;
    --check-config)
        check_config=true
        shift
        ;;
    *) ;;
esac
[[ $# -eq 0 ]] || die "unexpected argument: ${1}"

load_environment

: "${VAULTWARDEN_BACKUP_ROOT:?VAULTWARDEN_BACKUP_ROOT is required}"

readonly BACKUP_ROOT="${VAULTWARDEN_BACKUP_ROOT}"
readonly SNAPSHOTS_DIR="${BACKUP_ROOT}/snapshots"
readonly STANDBY_MOUNT="${VAULTWARDEN_STANDBY_MOUNT:-}"
readonly CONTAINER_LABEL="${VAULTWARDEN_CONTAINER_LABEL:-com.docker.compose.service=vaultwarden}"
readonly RETENTION_DAYS="${VAULTWARDEN_RETENTION_DAYS:-7}"
readonly MAX_UPLOAD_MIB="${VAULTWARDEN_MAX_UPLOAD_MIB:-20480}"

[[ "${BACKUP_ROOT}" == /* ]] || die "VAULTWARDEN_BACKUP_ROOT must be an absolute path"
[[ -z "${STANDBY_MOUNT}" || "${STANDBY_MOUNT}" == /* ]] ||
    die "VAULTWARDEN_STANDBY_MOUNT must be empty or an absolute path"
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die "VAULTWARDEN_RETENTION_DAYS must be a non-negative integer"
[[ "${MAX_UPLOAD_MIB}" =~ ^[1-9][0-9]*$ ]] || die "VAULTWARDEN_MAX_UPLOAD_MIB must be a positive integer"
[[ "${CONTAINER_LABEL}" != *[[:space:]]* ]] || die "VAULTWARDEN_CONTAINER_LABEL must not contain whitespace"

if [[ "${check_config}" == true ]]; then
    printf 'vaultwarden_backup_receive.sh configuration is valid\n'
    exit 0
fi

for command_name in awk flock sha256sum sqlite3 stat tar; do
    require_command "${command_name}"
done
if [[ -n "${STANDBY_MOUNT}" ]]; then
    require_command docker
fi

mkdir -p -- "${SNAPSHOTS_DIR}"
exec 9>"${BACKUP_ROOT}/receive.lock"
flock -w 300 9 || die "timed out waiting for the receiver lock"

archive="$(mktemp "${BACKUP_ROOT}/.incoming.XXXXXX.tar.gz")"
incoming="$(mktemp -d "${BACKUP_ROOT}/.extract.XXXXXX")"
listing="$(mktemp "${BACKUP_ROOT}/.listing.XXXXXX")"
standby_stage=""

cleanup() {
    rm -f -- "${archive}" "${listing}"
    [[ ! -d "${incoming}" ]] || rm -rf -- "${incoming}"
    [[ -z "${standby_stage}" || ! -d "${standby_stage}" ]] || rm -rf -- "${standby_stage}"
}
trap cleanup EXIT

# Bash ulimit -f is expressed in KiB on Linux.
ulimit -f "$((MAX_UPLOAD_MIB * 1024))"
cat >"${archive}"
[[ -s "${archive}" ]] || die "received archive is empty"

tar -tzf "${archive}" >"${listing}"
while IFS= read -r entry; do
    case "${entry}" in
        "" | /* | ../* | */../* | */..)
            die "archive contains an unsafe path"
            ;;
        *) ;;
    esac
done <"${listing}"

tar -tvzf "${archive}" |
    awk '{ type=substr($1,1,1); if (type != "-" && type != "d") exit 1 }' ||
    die "archive contains an unsupported entry type"

tar --no-same-owner --no-same-permissions -xzf "${archive}" -C "${incoming}"

[[ -f "${incoming}/SNAPSHOT_ID" && -f "${incoming}/SHA256SUMS" ]] ||
    die "snapshot metadata is incomplete"
snapshot_id="$(<"${incoming}/SNAPSHOT_ID")"
[[ "${snapshot_id}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "snapshot ID is invalid"
[[ -f "${incoming}/data/db.sqlite3" ]] || die "snapshot database is missing"
compgen -G "${incoming}/data/rsa_key*" >/dev/null || die "snapshot RSA keys are missing"

awk '
    NF != 2 || $1 !~ /^[0-9a-f]{64}$/ || $2 !~ /^data\// ||
    $2 ~ /(^|\/)\.\.(\/|$)/ { exit 1 }
' "${incoming}/SHA256SUMS" || die "checksum manifest is invalid"
(
    cd -- "${incoming}"
    sha256sum --check --strict SHA256SUMS >/dev/null
) || die "snapshot checksum verification failed"
database_check="$(sqlite3 "${incoming}/data/db.sqlite3" 'PRAGMA integrity_check;')"
[[ "${database_check}" == "ok" ]] || die "snapshot failed SQLite integrity_check"

destination="${SNAPSHOTS_DIR}/${snapshot_id}"
[[ ! -e "${destination}" ]] || die "snapshot already exists: ${snapshot_id}"
mv -- "${incoming}" "${destination}"

latest_tmp="${BACKUP_ROOT}/.latest.${snapshot_id}"
ln -s "snapshots/${snapshot_id}" "${latest_tmp}"
mv -Tf -- "${latest_tmp}" "${BACKUP_ROOT}/latest"

if [[ -n "${STANDBY_MOUNT}" ]]; then
    exec 8>"${BACKUP_ROOT}/standby.lock"
    flock -w 300 8 || die "timed out waiting for the standby lock"

    if docker ps -q --filter "label=${CONTAINER_LABEL}" | grep -q .; then
        printf 'vaultwarden is running; standby refresh skipped\n'
    else
        standby_data="${STANDBY_MOUNT}/data"
        standby_previous="${STANDBY_MOUNT}/data.previous"
        standby_stage="$(mktemp -d "${STANDBY_MOUNT}/.standby.XXXXXX")"

        cp -a -- "${destination}/data/." "${standby_stage}/"
        rm -f -- "${standby_stage}/db.sqlite3-wal" "${standby_stage}/db.sqlite3-shm"
        database_check="$(sqlite3 "${standby_stage}/db.sqlite3" 'PRAGMA integrity_check;')"
        [[ "${database_check}" == "ok" ]] || die "staged standby database failed integrity_check"

        [[ ! -e "${standby_previous}" ]] || rm -rf -- "${standby_previous}"
        [[ ! -e "${standby_data}" ]] || mv -- "${standby_data}" "${standby_previous}"
        if ! mv -- "${standby_stage}" "${standby_data}"; then
            [[ ! -d "${standby_previous}" ]] || mv -- "${standby_previous}" "${standby_data}"
            die "failed to publish standby data"
        fi
        standby_stage=""
        printf 'vaultwarden standby refreshed: %s\n' "${snapshot_id}"
    fi
fi

find "${SNAPSHOTS_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf -- {} +
printf 'vaultwarden snapshot stored: %s\n' "${snapshot_id}"
