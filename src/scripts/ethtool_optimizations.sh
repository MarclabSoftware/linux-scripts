#!/usr/bin/env bash

# Ethernet Offload Optimizer
# Version: 1.0.0
# Updated: 2026-07-29
#
# Applies configured ethtool feature states to matching network interfaces.
# Interface patterns and feature choices are loaded from an optional sidecar;
# the defaults cover predictable and traditional Ethernet interface names.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/ethtool_optimizations.env"

die() {
    printf 'ethtool_optimizations: %s\n' "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${ETHTOOL_ENV_FILE:-${DEFAULT_ENV_FILE}}"
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

INTERFACE_PATTERNS="${ETHTOOL_INTERFACE_PATTERNS:-en* eth*}"
FEATURE_SETTINGS="${ETHTOOL_FEATURE_SETTINGS:-rx-udp-gro-forwarding=on}"
SYSFS_NET_DIR="${ETHTOOL_SYSFS_NET_DIR:-/sys/class/net}"
DRY_RUN=0

validate_config() {
    local pattern setting
    local -a patterns settings

    [[ "${SYSFS_NET_DIR}" == /* ]] ||
        die "ETHTOOL_SYSFS_NET_DIR must be an absolute path"
    IFS=' ' read -r -a patterns <<<"${INTERFACE_PATTERNS}"
    IFS=' ' read -r -a settings <<<"${FEATURE_SETTINGS}"
    ((${#patterns[@]} > 0)) || die "ETHTOOL_INTERFACE_PATTERNS must not be empty"
    ((${#settings[@]} > 0)) || die "ETHTOOL_FEATURE_SETTINGS must not be empty"

    for pattern in "${patterns[@]}"; do
        [[ "${pattern}" =~ ^[A-Za-z0-9_.?*-]+$ ]] ||
            die "invalid interface pattern: ${pattern}"
    done
    for setting in "${settings[@]}"; do
        [[ "${setting}" =~ ^[A-Za-z0-9_-]+=(on|off)$ ]] ||
            die "invalid feature setting: ${setting}"
    done
}

case "${1:-}" in
    --check-config)
        (($# == 1)) || die "--check-config accepts no additional arguments"
        validate_config
        printf 'ethtool_optimizations configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf '%s\n' \
            'Usage: ethtool_optimizations.sh [--check-config | --dry-run]' \
            'Configuration: ethtool_optimizations.env beside the script.'
        exit 0
        ;;
    --dry-run)
        (($# == 1)) || die "--dry-run accepts no additional arguments"
        DRY_RUN=1
        ;;
    "")
        (($# == 0)) || die "unexpected arguments"
        ;;
    *) die "unknown argument: $1" ;;
esac

validate_config
if [[ "${DRY_RUN}" == "0" ]]; then
    ((EUID == 0)) || die "run this script as root"
    command -v ethtool >/dev/null 2>&1 || die "required command not found: ethtool"
fi
[[ -d "${SYSFS_NET_DIR}" ]] || die "network sysfs directory not found: ${SYSFS_NET_DIR}"

IFS=' ' read -r -a patterns <<<"${INTERFACE_PATTERNS}"
IFS=' ' read -r -a settings <<<"${FEATURE_SETTINGS}"
declare -A processed=()
matched=0
shopt -s nullglob
for pattern in "${patterns[@]}"; do
    # Patterns are validated above and expansion is intentionally limited to
    # the configured sysfs network directory.
    # shellcheck disable=SC2086
    for interface_path in "${SYSFS_NET_DIR}"/${pattern}; do
        interface_name="${interface_path##*/}"
        [[ "${interface_name}" != "lo" && -z "${processed[${interface_name}]:-}" ]] ||
            continue
        processed["${interface_name}"]=1
        ((++matched))

        for setting in "${settings[@]}"; do
            feature="${setting%%=*}"
            state="${setting#*=}"
            if [[ "${DRY_RUN}" == "1" ]]; then
                printf 'ethtool -K %s %s %s\n' "${interface_name}" "${feature}" "${state}"
            else
                ethtool -K "${interface_name}" "${feature}" "${state}"
            fi
        done
    done
done
shopt -u nullglob

((matched > 0)) || die "no interfaces matched ETHTOOL_INTERFACE_PATTERNS"
