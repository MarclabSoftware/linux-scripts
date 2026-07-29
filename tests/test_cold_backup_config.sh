#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

cat >"${TEST_TMP}/cold_backup.env" <<'EOF'
COLD_BACKUP_NVME_UUID=test-uuid
COLD_BACKUP_NVME_MOUNT=/mnt/test-backup
COLD_BACKUP_NVME_DATA_SOURCE=/srv/data/
COLD_BACKUP_SOURCE_MOUNT=/srv
COLD_BACKUP_HOME_SOURCE=/home/test-user/data
EOF
chmod 0600 "${TEST_TMP}/cold_backup.env"

COLD_BACKUP_ENV_FILE="${TEST_TMP}/cold_backup.env" \
    "${REPO_ROOT}/src/scripts/cold_backup.sh" --check-config |
    grep -Fx 'cold_backup configuration is valid' >/dev/null

chmod 0666 "${TEST_TMP}/cold_backup.env"
if COLD_BACKUP_ENV_FILE="${TEST_TMP}/cold_backup.env" \
    "${REPO_ROOT}/src/scripts/cold_backup.sh" --check-config 2>/dev/null; then
    printf 'world-writable environment file was unexpectedly accepted\n' >&2
    exit 1
fi
