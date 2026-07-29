#!/usr/bin/env bash

# Shared Media Script Helpers
# Version: 1.0.0
# Updated: 2026-07-29
#
# Small shared primitives for the media maintenance scripts: trusted sidecar
# loading, consistent logging, dependency checks and collision-free temporary
# directories. This file is a library and is not intended to be executed.

media_die() {
    printf 'media: %s\n' "$*" >&2
    exit 1
}

media_load_environment() {
    local env_file="${MEDIA_ENV_FILE:-${MEDIA_SCRIPT_DIR}/media_tools.env}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] ||
        media_die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) ||
        media_die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

media_initialize() {
    media_load_environment

    MEDIA_LOG_FILE="${MEDIA_LOG_FILE:-}"
    MEDIA_TEMP_ROOT="${MEDIA_TEMP_ROOT:-${TMPDIR:-/tmp}}"
    [[ -z "${MEDIA_LOG_FILE}" || "${MEDIA_LOG_FILE}" == /* ]] ||
        media_die "MEDIA_LOG_FILE must be empty or an absolute path"
    [[ "${MEDIA_TEMP_ROOT}" == /* ]] ||
        media_die "MEDIA_TEMP_ROOT must be an absolute path"

    if [[ -n "${MEDIA_LOG_FILE}" ]]; then
        mkdir -p -- "$(dirname -- "${MEDIA_LOG_FILE}")"
    fi
}

media_log() {
    local level="$1"
    shift
    local message
    message="$(printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s' -1 "${level}" "$*")"
    printf '%s\n' "${message}" >&2
    [[ -z "${MEDIA_LOG_FILE}" ]] || printf '%s\n' "${message}" >>"${MEDIA_LOG_FILE}"
}

media_require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        media_die "required command not found: $1"
}

media_make_temp_dir() {
    local prefix="$1"
    mkdir -p -- "${MEDIA_TEMP_ROOT}"
    mktemp -d -- "${MEDIA_TEMP_ROOT%/}/${prefix}.XXXXXX"
}

media_validate_boolean() {
    local name="$1"
    local value="$2"
    [[ "${value}" == "0" || "${value}" == "1" ]] ||
        media_die "${name} must be 0 or 1"
}
