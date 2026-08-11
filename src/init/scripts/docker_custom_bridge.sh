#!/usr/bin/env bash

# Provisioning module: custom Docker bridge network.
#
# Creates one local bridge with Docker-managed IPAM. An existing network is
# reused only when its driver is already bridge; mismatches require deliberate
# administrator intervention and are never deleted automatically.
#
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

validateCustomDockerBridgeConfiguration() {
    [[ -v CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME ]] || {
        printf 'Missing CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME configuration\n' >&2
        return 1
    }
    validateDockerNetworkName \
        "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}"
}

createCustomDockerBridgeNetwork() {
    local driver

    validateCustomDockerBridgeConfiguration || return
    checkCommand docker || return
    docker info --format '{{.ServerVersion}}' >/dev/null || {
        printf 'Docker daemon is not available\n' >&2
        return 1
    }

    printf '\nConfiguring Docker bridge network %s\n' \
        "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}"
    if driver="$(docker network inspect --format '{{.Driver}}' -- \
        "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}" 2>/dev/null)"; then
        [[ "${driver}" == bridge ]] || {
            printf 'Docker network %s uses driver %s, expected bridge\n' \
                "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}" \
                "${driver}" >&2
            return 1
        }
        printf 'Docker bridge network %s already matches\n' \
            "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}"
        return 0
    fi

    docker network create --driver bridge -- \
        "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}" >/dev/null
    printf 'Docker bridge network %s created\n' \
        "${CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME}"
}
