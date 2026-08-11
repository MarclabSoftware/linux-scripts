#!/usr/bin/env bash

# Exercise Docker login argument construction without contacting a registry.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

fake_bin="${TEST_TMP}/bin"
sudo_log="${TEST_TMP}/sudo.log"
mkdir -p -- "${fake_bin}"

for command_name in docker sudo; do
    command_file="${fake_bin}/${command_name}"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        if [[ "${command_name}" == sudo ]]; then
            printf 'printf "%%s\\n" "$*" >>"%s"\n' "${sudo_log}"
        else
            printf '%s\n' 'exit 0'
        fi
    } >"${command_file}"
    chmod 0755 -- "${command_file}"
done

PATH="${fake_bin}:${PATH}"
CONFIG_USER="deploy-user"

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/docker_login.sh
. "${REPO_ROOT}/src/init/scripts/docker_login.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

CONFIG_DOCKER_REGISTRY=""
CONFIG_DOCKER_USERNAME=""
dockerLogin >/dev/null
grep -Fx -- \
    "-H -u deploy-user -- ${fake_bin}/docker login" "${sudo_log}" >/dev/null

: >"${sudo_log}"
CONFIG_DOCKER_REGISTRY="registry.example.com:5443"
CONFIG_DOCKER_USERNAME="deploy-user"
dockerLogin >/dev/null
grep -Fx -- \
    "-H -u deploy-user -- ${fake_bin}/docker login --username deploy-user registry.example.com:5443" \
    "${sudo_log}" >/dev/null

CONFIG_DOCKER_REGISTRY="https://registry.example.com/project"
expect_failure validateDockerLoginConfiguration

CONFIG_DOCKER_REGISTRY="registry.example.com"
CONFIG_DOCKER_USERNAME="invalid user"
expect_failure validateDockerLoginConfiguration

printf 'Docker login tests passed\n'
