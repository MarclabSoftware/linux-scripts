#!/usr/bin/env bash

# Docker Bridge Network Provisioner
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

network_format='{{.Driver}}{{println}}{{.EnableIPv6}}{{range .IPAM.Config}}{{println}}{{.Subnet}}|{{.Gateway}}{{end}}'
if network_snapshot="$(docker network inspect --format "${network_format}" "${NETWORK_NAME}" 2>/dev/null)"; then
    mapfile -t network_info <<<"${network_snapshot}"
    ((${#network_info[@]} >= 2)) || die "Docker returned incomplete network details"
    existing_driver="${network_info[0]}"
    [[ "${existing_driver}" == "${NETWORK_DRIVER}" ]] ||
        die "existing network ${NETWORK_NAME} uses driver ${existing_driver}, expected ${NETWORK_DRIVER}"
    if [[ -n "${DOCKER_NETWORK_ENABLE_IPV6+x}" ]]; then
        expected_ipv6=false
        [[ "${ENABLE_IPV6}" != 1 ]] || expected_ipv6=true
        [[ "${network_info[1]}" == "${expected_ipv6}" ]] ||
            die "existing network ${NETWORK_NAME} has IPv6=${network_info[1]}, expected ${expected_ipv6}"
    fi
    ipv4_matches=false
    ipv6_matches=false
    for pool in "${network_info[@]:2}"; do
        IFS='|' read -r subnet gateway <<<"${pool}"
        if [[ "${subnet}" == "${IPV4_SUBNET}" && (-z "${IPV4_GATEWAY}" || "${gateway}" == "${IPV4_GATEWAY}") ]]; then
            ipv4_matches=true
        fi
        if [[ "${subnet}" == "${IPV6_SUBNET}" && (-z "${IPV6_GATEWAY}" || "${gateway}" == "${IPV6_GATEWAY}") ]]; then
            ipv6_matches=true
        fi
    done
    [[ -z "${IPV4_SUBNET}" || "${ipv4_matches}" == true ]] ||
        die "existing network ${NETWORK_NAME} does not match the requested IPv4 subnet/gateway"
    [[ -z "${IPV6_SUBNET}" || "${ipv6_matches}" == true ]] ||
        die "existing network ${NETWORK_NAME} does not match the requested IPv6 subnet/gateway"
    exit 0
fi

# A failed inspect is not evidence that a network is absent (the daemon may be
# unavailable). Confirm absence before attempting creation.
network_names="$(docker network ls --format '{{.Name}}')" || die "cannot list Docker networks"
while IFS= read -r existing_name; do
    [[ "${existing_name}" != "${NETWORK_NAME}" ]] || die "cannot inspect existing network ${NETWORK_NAME}"
done <<<"${network_names}"

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
