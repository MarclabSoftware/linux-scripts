#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

paths_file="${TEST_TMP}/update.paths"
printf '/etc/hosts\n' >"${paths_file}"

for platform in debian arch; do
    env_file="${TEST_TMP}/update_${platform}.env"
    cat >"${env_file}" <<EOF
SYSTEM_UPDATE_BACKUP_ENABLED=1
SYSTEM_UPDATE_BACKUP_DIR=${TEST_TMP}/backups
SYSTEM_UPDATE_BACKUP_PATHS_FILE=${paths_file}
EOF
    chmod 0600 "${env_file}"

    SYSTEM_UPDATE_ENV_FILE="${env_file}" \
        "${REPO_ROOT}/src/scripts/update_${platform}.sh" --check-config |
        grep -Fx "update_${platform} configuration is valid" >/dev/null

    chmod 0666 "${env_file}"
    if SYSTEM_UPDATE_ENV_FILE="${env_file}" \
        "${REPO_ROOT}/src/scripts/update_${platform}.sh" --check-config 2>/dev/null; then
        printf '%s accepted a world-writable environment file\n' "update_${platform}" >&2
        exit 1
    fi
done
