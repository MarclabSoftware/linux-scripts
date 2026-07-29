#!/usr/bin/env bash

# MQTT Power-State Publisher
# Version: 1.0.0
# Updated: 2026-07-29
#
# Publishes a Linux power-supply state through mosquitto_pub. Broker credentials
# and connection options stay in a private mosquitto_pub options file, while
# host-specific paths are supplied by power_state.env beside this script.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/power_state.env"

die() {
    printf 'power_state: %s\n' "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${POWER_STATE_ENV_FILE:-${DEFAULT_ENV_FILE}}"
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

readonly STATE_FILE="${POWER_STATE_SOURCE_FILE:-}"
readonly OPTIONS_FILE="${POWER_STATE_MQTT_OPTIONS_FILE:-}"

for configured_path in "${STATE_FILE}" "${OPTIONS_FILE}"; do
    [[ "${configured_path}" == /* ]] || die "configured file paths must be absolute"
    [[ -r "${configured_path}" ]] || die "configured file is not readable: ${configured_path}"
done

case "${1:-}" in
    --check-config)
        printf 'power_state configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: power_state.sh [--check-config]\n'
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1" ;;
esac

command -v mosquitto_pub >/dev/null 2>&1 ||
    die "required command not found: mosquitto_pub"

IFS= read -r power_state <"${STATE_FILE}" ||
    die "cannot read power state: ${STATE_FILE}"
[[ "${power_state}" == "0" || "${power_state}" == "1" ]] ||
    die "power state must be 0 or 1"

printf '%s\n' "${power_state}" |
    mosquitto_pub -o "${OPTIONS_FILE}" -s
