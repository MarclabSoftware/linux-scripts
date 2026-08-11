#!/usr/bin/env bash

# Exercise phase-two restore and Compose startup without touching Docker.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/backup_restore.sh
. "${REPO_ROOT}/src/init/scripts/backup_restore.sh"
# shellcheck source=src/init/scripts/docker_compose_start.sh
. "${REPO_ROOT}/src/init/scripts/docker_compose_start.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

source_directory="${TEST_TMP}/source"
restore_directory="${TEST_TMP}/restore"
mkdir -p -- "${source_directory}/etc" "${restore_directory}"
printf 'restored\n' >"${source_directory}/etc/example.conf"
CONFIG_BACKUP_FILE_PATH="${TEST_TMP}/backup.tar"
CONFIG_BACKUP_RESTORE_DESTINATION="${restore_directory}"
tar --create --file "${CONFIG_BACKUP_FILE_PATH}" \
    --directory "${source_directory}" .

validateBackupRestoreConfiguration
restoreBackup >/dev/null
grep -Fx 'restored' "${restore_directory}/etc/example.conf" >/dev/null

CONFIG_BACKUP_RESTORE_DESTINATION="relative"
expect_failure validateBackupRestoreConfiguration
CONFIG_BACKUP_RESTORE_DESTINATION="${restore_directory}"

malicious_archive="${TEST_TMP}/traversal.tar"
tar --create --file "${malicious_archive}" \
    --transform='s|^etc|../etc|' \
    --directory "${source_directory}" etc/example.conf
expect_failure validateBackupArchive "${malicious_archive}"

compose_file="${TEST_TMP}/compose.yaml"
printf '%s\n' \
    'services:' \
    '  test:' \
    '    image: example.invalid/test:latest' >"${compose_file}"
CONFIG_DOCKER_COMPOSE_FILE_PATH="${compose_file}"
docker_log="${TEST_TMP}/docker.log"

docker() {
    printf '%s\n' "$*" >>"${docker_log}"
}

validateDockerComposeConfiguration
startDockerCompose >/dev/null
grep -Fx 'compose version' "${docker_log}" >/dev/null
grep -Fx "compose --file ${compose_file} config --quiet" \
    "${docker_log}" >/dev/null
grep -Fx 'info --format {{.ServerVersion}}' "${docker_log}" >/dev/null
grep -Fx "compose --file ${compose_file} up --detach" \
    "${docker_log}" >/dev/null

CONFIG_DOCKER_COMPOSE_FILE_PATH="compose.yaml"
expect_failure validateDockerComposeConfiguration

printf 'init restore and Compose tests passed\n'
