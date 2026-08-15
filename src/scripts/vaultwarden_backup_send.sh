#!/usr/bin/env bash

# Vaultwarden Backup Sender
# Version: 2.0.0
# Updated: 2026-07-29
#
# Creates a transactionally consistent Vaultwarden snapshot and streams it to
# a restricted SSH receiver. Deployment-specific paths and SSH settings belong
# in the adjacent vaultwarden_backup_send.env file or in exported variables.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/vaultwarden_backup_send.env"

die() {
    printf 'vaultwarden_backup_send.sh: %s\n' "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${VAULTWARDEN_SEND_ENV_FILE:-${DEFAULT_ENV_FILE}}"
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
Usage: vaultwarden_backup_send.sh [--check-config]

  --check-config  Validate configuration and required local paths, then exit.
EOF
}

check_config=false
case "${1:-}" in
    --help | -h)
        usage
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

: "${VAULTWARDEN_DATA_DIR:?VAULTWARDEN_DATA_DIR is required}"
: "${VAULTWARDEN_BACKUP_TARGET:?VAULTWARDEN_BACKUP_TARGET is required}"
: "${VAULTWARDEN_BACKUP_SSH_KEY:?VAULTWARDEN_BACKUP_SSH_KEY is required}"

readonly DATA_DIR="${VAULTWARDEN_DATA_DIR}"
readonly STATE_DIR="${VAULTWARDEN_BACKUP_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/vaultwarden-backup}"
readonly SSH_TARGET="${VAULTWARDEN_BACKUP_TARGET}"
readonly SSH_KEY="${VAULTWARDEN_BACKUP_SSH_KEY}"
readonly SSH_PORT="${VAULTWARDEN_BACKUP_SSH_PORT:-22}"
readonly SSH_KNOWN_HOSTS="${VAULTWARDEN_BACKUP_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
readonly REMOTE_COMMAND="${VAULTWARDEN_BACKUP_REMOTE_COMMAND:-vaultwarden-backup}"

[[ "${DATA_DIR}" == /* ]] || die "VAULTWARDEN_DATA_DIR must be an absolute path"
[[ -d "${DATA_DIR}" ]] || die "Vaultwarden data directory does not exist: ${DATA_DIR}"
[[ -f "${DATA_DIR}/db.sqlite3" ]] || die "Vaultwarden database not found: ${DATA_DIR}/db.sqlite3"
[[ -r "${SSH_KEY}" ]] || die "SSH private key is not readable: ${SSH_KEY}"
[[ -r "${SSH_KNOWN_HOSTS}" ]] || die "SSH known-hosts file is not readable: ${SSH_KNOWN_HOSTS}"
if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
    die "VAULTWARDEN_BACKUP_SSH_PORT must be between 1 and 65535"
fi
[[ "${SSH_TARGET}" != *[[:space:]]* ]] || die "VAULTWARDEN_BACKUP_TARGET must not contain whitespace"
[[ "${REMOTE_COMMAND}" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "VAULTWARDEN_BACKUP_REMOTE_COMMAND contains unsupported characters"

if [[ "${check_config}" == true ]]; then
    printf 'vaultwarden_backup_send.sh configuration is valid\n'
    exit 0
fi

for command_name in flock sha256sum sqlite3 ssh stat tar; do
    require_command "${command_name}"
done

mkdir -p -- "${STATE_DIR}"
exec 9>"${STATE_DIR}/backup.lock"
flock -n 9 || {
    printf 'vaultwarden backup is already running\n' >&2
    exit 0
}

stage="$(mktemp -d "${STATE_DIR}/stage.XXXXXX")"
trap 'rm -rf -- "${stage}"' EXIT
mkdir -- "${stage}/data"

# SQLite's Online Backup API includes committed WAL content without downtime.
sqlite3 "${DATA_DIR}/db.sqlite3" ".backup '${stage}/data/db.sqlite3'"
database_check="$(sqlite3 "${stage}/data/db.sqlite3" 'PRAGMA quick_check;')"
[[ "${database_check}" == "ok" ]] || die "the database snapshot failed SQLite quick_check"

# RSA keys preserve existing JWT sessions. Attachments and Sends are stored
# outside SQLite, while config.json is optional.
find "${DATA_DIR}" -maxdepth 1 -type f -name 'rsa_key*' -exec cp -a -t "${stage}/data" -- {} +
compgen -G "${stage}/data/rsa_key*" >/dev/null || die "Vaultwarden RSA keys were not found"
[[ ! -f "${DATA_DIR}/config.json" ]] || cp -a -- "${DATA_DIR}/config.json" "${stage}/data/"
for directory_name in attachments sends; do
    [[ ! -d "${DATA_DIR}/${directory_name}" ]] ||
        cp -a -- "${DATA_DIR}/${directory_name}" "${stage}/data/"
done

date -u +%Y%m%dT%H%M%SZ >"${stage}/SNAPSHOT_ID"
(
    cd -- "${stage}"
    find data -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum >SHA256SUMS
)

tar -C "${stage}" -czf - SNAPSHOT_ID SHA256SUMS data |
    ssh -T \
        -i "${SSH_KEY}" \
        -p "${SSH_PORT}" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o IdentitiesOnly=yes \
        -o ServerAliveInterval=15 \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
        "${SSH_TARGET}" "${REMOTE_COMMAND}"

snapshot_id="$(<"${stage}/SNAPSHOT_ID")"
printf 'vaultwarden backup sent: %s\n' "${snapshot_id}"
