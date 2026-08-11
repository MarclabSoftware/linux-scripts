#!/usr/bin/env bash

# Exercise Docker bridge provisioning without touching the daemon.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/docker_custom_bridge.sh
. "${REPO_ROOT}/src/init/scripts/docker_custom_bridge.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME="bridge_test"
validateCustomDockerBridgeConfiguration
CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME="--invalid"
expect_failure validateCustomDockerBridgeConfiguration
CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME="bridge_test"

docker_log="${TEST_TMP}/docker.log"
network_exists=false
network_driver=""

docker() {
    local format="" name=""

    if [[ "$1" == info ]]; then
        printf '29.0.0\n'
        return 0
    fi
    [[ "$1" == network ]] || return 2

    case "$2" in
        inspect)
            if [[ "${3:-}" == --format ]]; then
                format="$4"
                name="$6"
            else
                name="$3"
            fi
            [[ "${network_exists}" == true &&
                "${name}" == "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}" ]] ||
                return 1
            case "${format}" in
                '') ;;
                '{{.Driver}}') printf '%s\n' "${network_driver}" ;;
                *) return 2 ;;
            esac
            ;;
        create)
            printf '%s\n' "$*" >>"${docker_log}"
            network_exists=true
            network_driver="bridge"
            ;;
        *) return 2 ;;
    esac
}

createCustomDockerBridgeNetwork >/dev/null
grep -Fx 'network create --driver bridge -- bridge_test' \
    "${docker_log}" >/dev/null
createCustomDockerBridgeNetwork >/dev/null
create_count="$(grep -cFx 'network create --driver bridge -- bridge_test' \
    "${docker_log}")"
[[ "${create_count}" == 1 ]]

network_driver="overlay"
expect_failure createCustomDockerBridgeNetwork

printf 'init Docker bridge tests passed\n'
