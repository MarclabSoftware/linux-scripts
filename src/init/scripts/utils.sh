#!/usr/bin/env bash

# Shared helpers for the provisioning modules.
#
# This file is sourced by init.sh and intentionally does not change shell
# options or terminate the caller. Helpers report failures through return
# values so init.sh can stop safely under `set -e`.

# Return success only when running as root.
checkSU() {
    if ((EUID != 0)); then
        printf 'Please run as root\n' >&2
        return 1
    fi
}

# Return success when the named configuration variable exists and is non-empty.
checkConfig() {
    if (($# != 1)) || [[ -z "$1" ]]; then
        printf 'checkConfig: expected one configuration variable name\n' >&2
        return 2
    fi

    local config_name="$1"
    if [[ ! "${config_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        printf 'checkConfig: invalid variable name: %s\n' "${config_name}" >&2
        return 2
    fi
    if [[ ! -v "${config_name}" || -z "${!config_name}" ]]; then
        printf 'Missing or empty %s configuration\n' "${config_name}" >&2
        return 1
    fi
}

# Return success when the requested command is available.
checkCommand() {
    if (($# != 1)) || [[ -z "$1" ]]; then
        printf 'checkCommand: expected one command name\n' >&2
        return 2
    fi
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        return 1
    fi
}

# Validate a conservative Docker network name before passing it to the CLI.
validateDockerNetworkName() {
    if (($# != 1)) ||
        [[ ! "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        printf 'Docker network names must use letters, digits, dot, underscore or hyphen\n' >&2
        return 1
    fi
}

# Atomically install a mode-0644 configuration file from standard input.
# Refuse symbolic-link targets so a privileged provisioning run cannot be
# redirected outside the intended configuration path.
installConfigFile() {
    if (($# != 1)) || [[ "$1" != /* ]]; then
        printf 'installConfigFile: expected one absolute target path\n' >&2
        return 2
    fi

    local target="$1"
    local target_dir="${target%/*}"
    local temporary

    [[ -n "${target_dir}" ]] || target_dir="/"
    [[ ! -d "${target}" ]] || {
        printf 'installConfigFile: target is a directory: %s\n' \
            "${target}" >&2
        return 1
    }
    [[ ! -L "${target}" ]] || {
        printf 'installConfigFile: symbolic-link target rejected: %s\n' \
            "${target}" >&2
        return 1
    }
    if [[ ! -d "${target_dir}" ]]; then
        install -d -m 0755 -- "${target_dir}"
    fi

    temporary="$(mktemp -- "${target_dir}/.${target##*/}.XXXXXX")"
    if ! cat >"${temporary}" || ! chmod 0644 -- "${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi

    if cmp -s -- "${temporary}" "${target}"; then
        rm -f -- "${temporary}"
        chmod 0644 -- "${target}"
    elif ! mv -f -- "${temporary}" "${target}"; then
        rm -f -- "${temporary}"
        return 1
    fi
}

# Return success when the model file belongs to a Raspberry Pi.
isRaspberryPi() {
    if (($# > 1)); then
        printf 'isRaspberryPi: expected an optional model-file path\n' >&2
        return 2
    fi

    local model_file="${1:-/proc/device-tree/model}"

    [[ -r "${model_file}" ]] &&
        grep -aFq 'Raspberry Pi ' "${model_file}"
}

# Return success when the account exists and does not have UID 0.
isNormalUser() {
    if (($# != 1)) || [[ -z "$1" ]]; then
        return 1
    fi

    local user_id
    user_id="$(id -u -- "$1" 2>/dev/null)" || return 1
    ((user_id != 0))
}

# Enable a systemd unit and optionally start it immediately.
# Arguments: UNIT [true|false]
enableService() {
    if (($# < 1 || $# > 2)) || [[ -z "$1" ]]; then
        printf 'enableService: expected UNIT [true|false]\n' >&2
        return 2
    fi

    local service_name="$1"
    local start_service="${2:-false}"

    case "${start_service}" in
        true)
            systemctl enable --now "${service_name}"
            printf '%s enabled and started\n' "${service_name}"
            ;;
        false)
            systemctl enable "${service_name}"
            printf '%s enabled\n' "${service_name}"
            ;;
        *)
            printf 'enableService: second argument must be true or false\n' >&2
            return 2
            ;;
    esac
}
