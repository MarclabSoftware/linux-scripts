#!/usr/bin/env bash

# Docker Bridge Network Provisioner
# Version: 2.0.0
# Updated: 2026-07-29
#
# Idempotently creates one Docker network. Host-specific IPAM settings may be
# supplied through docker_network.env beside this script or through the process
# environment. Existing networks are never replaced automatically.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/docker_network.env"

die() {
    printf 'docker_network: %s\n' "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${DOCKER_NETWORK_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] ||
        die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) ||
        die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

load_environment

readonly NETWORK_NAME="${DOCKER_NETWORK_NAME:-custom_bridge}"
readonly NETWORK_DRIVER="${DOCKER_NETWORK_DRIVER:-bridge}"
readonly IPV4_SUBNET="${DOCKER_NETWORK_IPV4_SUBNET:-}"
readonly IPV4_GATEWAY="${DOCKER_NETWORK_IPV4_GATEWAY:-}"
readonly ENABLE_IPV6="${DOCKER_NETWORK_ENABLE_IPV6:-0}"
readonly IPV6_SUBNET="${DOCKER_NETWORK_IPV6_SUBNET:-}"
readonly IPV6_GATEWAY="${DOCKER_NETWORK_IPV6_GATEWAY:-}"

[[ -n "${NETWORK_NAME}" && "${NETWORK_NAME}" != *[[:space:]]* ]] ||
    die "DOCKER_NETWORK_NAME must be non-empty and contain no whitespace"
[[ -n "${NETWORK_DRIVER}" && "${NETWORK_DRIVER}" != *[[:space:]]* ]] ||
    die "DOCKER_NETWORK_DRIVER must be non-empty and contain no whitespace"
[[ "${ENABLE_IPV6}" == "0" || "${ENABLE_IPV6}" == "1" ]] ||
    die "DOCKER_NETWORK_ENABLE_IPV6 must be 0 or 1"
[[ -z "${IPV4_GATEWAY}" || -n "${IPV4_SUBNET}" ]] ||
    die "an IPv4 gateway requires an IPv4 subnet"
[[ -z "${IPV6_GATEWAY}" || -n "${IPV6_SUBNET}" ]] ||
    die "an IPv6 gateway requires an IPv6 subnet"
[[ "${ENABLE_IPV6}" == "1" ||
    (-z "${IPV6_SUBNET}" && -z "${IPV6_GATEWAY}") ]] ||
    die "IPv6 IPAM values require DOCKER_NETWORK_ENABLE_IPV6=1"

case "${1:-}" in
    --check-config)
        printf 'docker_network configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: docker_network.sh [--check-config]\n'
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker is not installed"

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    existing_driver="$(docker network inspect --format '{{.Driver}}' "${NETWORK_NAME}")"
    [[ "${existing_driver}" == "${NETWORK_DRIVER}" ]] ||
        die "existing network ${NETWORK_NAME} uses driver ${existing_driver}, expected ${NETWORK_DRIVER}"
    exit 0
fi

create_args=(--driver "${NETWORK_DRIVER}")
if [[ -n "${IPV4_SUBNET}" ]]; then
    create_args+=(--subnet "${IPV4_SUBNET}")
    [[ -z "${IPV4_GATEWAY}" ]] ||
        create_args+=(--gateway "${IPV4_GATEWAY}")
fi
if [[ "${ENABLE_IPV6}" == "1" ]]; then
    create_args+=(--ipv6)
    if [[ -n "${IPV6_SUBNET}" ]]; then
        create_args+=(--subnet "${IPV6_SUBNET}")
        [[ -z "${IPV6_GATEWAY}" ]] ||
            create_args+=(--gateway "${IPV6_GATEWAY}")
    fi
fi

docker network create "${create_args[@]}" "${NETWORK_NAME}" >/dev/null
