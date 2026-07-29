#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

mkdir -p -- "${TEST_TMP}/data" "${TEST_TMP}/state"
touch -- "${TEST_TMP}/data/db.sqlite3" "${TEST_TMP}/backup_key" "${TEST_TMP}/known_hosts"
chmod 0600 "${TEST_TMP}/backup_key" "${TEST_TMP}/known_hosts"

cat >"${TEST_TMP}/send.env" <<EOF
VAULTWARDEN_DATA_DIR=${TEST_TMP}/data
VAULTWARDEN_BACKUP_STATE_DIR=${TEST_TMP}/state
VAULTWARDEN_BACKUP_TARGET=backup-user@backup.example
VAULTWARDEN_BACKUP_SSH_KEY=${TEST_TMP}/backup_key
VAULTWARDEN_BACKUP_KNOWN_HOSTS=${TEST_TMP}/known_hosts
EOF

cat >"${TEST_TMP}/recovery.env" <<EOF
VAULTWARDEN_BACKUP_ROOT=${TEST_TMP}/backups
VAULTWARDEN_STACK_DIR=${TEST_TMP}/stack
VAULTWARDEN_STANDBY_MOUNT=
EOF
chmod 0600 "${TEST_TMP}/send.env" "${TEST_TMP}/recovery.env"

VAULTWARDEN_SEND_ENV_FILE="${TEST_TMP}/send.env" \
    "${REPO_ROOT}/src/scripts/vaultwarden_backup_send.sh" --check-config |
    grep -Fx 'vaultwarden_backup_send.sh configuration is valid' >/dev/null

VAULTWARDEN_RECOVERY_ENV_FILE="${TEST_TMP}/recovery.env" \
    "${REPO_ROOT}/src/scripts/vaultwarden_backup_receive.sh" --check-config |
    grep -Fx 'vaultwarden_backup_receive.sh configuration is valid' >/dev/null

VAULTWARDEN_RECOVERY_ENV_FILE="${TEST_TMP}/recovery.env" \
    "${REPO_ROOT}/src/scripts/vaultwarden_restore.sh" --check-config |
    grep -Fx 'vaultwarden_restore.sh configuration is valid' >/dev/null

"${REPO_ROOT}/src/scripts/vaultwarden_restore.sh" --help >/dev/null

chmod 0666 "${TEST_TMP}/send.env"
if VAULTWARDEN_SEND_ENV_FILE="${TEST_TMP}/send.env" \
    "${REPO_ROOT}/src/scripts/vaultwarden_backup_send.sh" --check-config 2>/dev/null; then
    printf 'world-writable environment file was unexpectedly accepted\n' >&2
    exit 1
fi
