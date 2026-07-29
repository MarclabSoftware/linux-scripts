#!/usr/bin/env bash

# SSH Security Audit
# Version: 2.0.0
# Updated: 2026-07-29
#
# Keeps a shallow ssh-audit checkout in the user cache and audits either the
# arguments supplied by the caller or the local SSH daemon. When run inside an
# SSH session, the local daemon port is inferred from SSH_CONNECTION.

set -Eeuo pipefail

readonly GIT_URL="https://github.com/jtesta/ssh-audit.git"
readonly TOOL_DIR="${SSH_AUDIT_TOOL_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/ssh-audit}"

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# The ERR trap invokes this function indirectly.
# shellcheck disable=SC2317,SC2329
error_handler() {
    local exit_code=$1
    local line_number=$2
    local last_command=$3

    printf "Error at line %d\nCommand: %s\nExit code: %d\n" \
        "${line_number}" "${last_command}" "${exit_code}" >&2
    exit "${exit_code}"
}

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "$1" "$2" >&2
}

[[ "${EUID}" -eq 0 ]] && {
    log "ERROR" "Do not run as root"
    exit 1
}

check_dependencies() {
    local -a missing_deps=()
    for cmd in git python3; do
        command -v "${cmd}" >/dev/null 2>&1 || missing_deps+=("${cmd}")
    done

    if ((${#missing_deps[@]} > 0)); then
        log "ERROR" "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

update_repository() {
    if [[ -d "${TOOL_DIR}/.git" ]]; then
        (cd "${TOOL_DIR}" && git pull --ff-only --depth 1 --no-tags) ||
            {
                log "ERROR" "Failed to update repository"
                exit 1
            }
    elif [[ -e "${TOOL_DIR}" ]]; then
        log "ERROR" "Tool path exists but is not a Git checkout: ${TOOL_DIR}"
        exit 1
    else
        mkdir -p -- "$(dirname -- "${TOOL_DIR}")"
        git clone --depth 1 --no-tags "${GIT_URL}" "${TOOL_DIR}" ||
            {
                log "ERROR" "Failed to clone repository"
                exit 1
            }
    fi
}

main() {
    log "INFO" "Starting SSH security audit"

    [[ "${TOOL_DIR}" == /* ]] || {
        log "ERROR" "SSH_AUDIT_TOOL_DIR must be an absolute path"
        exit 1
    }

    check_dependencies

    update_repository

    [[ -f "${TOOL_DIR}/ssh-audit.py" ]] || {
        log "ERROR" "ssh-audit.py not found"
        exit 1
    }

    local -a audit_params=()
    if [[ $# -eq 0 ]]; then
        # Prefer an explicit port, then the current SSH session's server port.
        # SSH_CONNECTION contains: client address, client port, server address,
        # and server port. Fall back to the standard SSH port outside a session.
        local -a connection_fields=()
        local audit_port
        read -r -a connection_fields <<<"${SSH_CONNECTION-}"
        audit_port="${SSH_AUDIT_PORT:-${connection_fields[3]:-22}}"

        if [[ ! "${audit_port}" =~ ^[0-9]{1,5}$ ]] ||
            ((10#${audit_port} < 1 || 10#${audit_port} > 65535)); then
            log "ERROR" "Invalid SSH_AUDIT_PORT: ${audit_port}"
            exit 1
        fi

        audit_params=(-4 -p "${audit_port}" localhost)
        log "INFO" "Using default target: localhost:${audit_port}"
    else
        audit_params=("$@")
        log "INFO" "Using custom parameters: ${audit_params[*]}"
    fi

    log "INFO" "Running ssh-audit..."
    "${TOOL_DIR}/ssh-audit.py" "${audit_params[@]}" || true

    log "INFO" "Audit completed successfully"
}

main "$@"
