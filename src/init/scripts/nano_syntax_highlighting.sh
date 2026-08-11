#!/usr/bin/env bash

# Provisioning Module: GNU nano
# Version: 3.0.0
# Updated: 2026-08-09
# Adds syntax definitions and line numbers to the normal user's and root's
# .nanorc files without replacing their other editor preferences.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

configureNanoFile() {
    if (($# != 3)); then
        printf 'configureNanoFile: expected FILE OWNER GROUP\n' >&2
        return 2
    fi

    local target="$1"
    local owner="$2"
    local group="$3"
    local target_dir="${target%/*}"
    local temporary
    local include_present=false
    local linenumbers_present=false

    [[ "${target}" == /* ]] || {
        printf 'Nano configuration path must be absolute: %s\n' "${target}" >&2
        return 2
    }
    [[ -n "${target_dir}" ]] || target_dir="/"
    [[ ! -L "${target}" ]] || {
        printf 'Refusing symbolic-link Nano configuration: %s\n' \
            "${target}" >&2
        return 1
    }
    [[ ! -e "${target}" || -f "${target}" ]] || {
        printf 'Nano configuration is not a regular file: %s\n' \
            "${target}" >&2
        return 1
    }
    [[ -d "${target_dir}" ]] || {
        printf 'Nano configuration directory does not exist: %s\n' \
            "${target_dir}" >&2
        return 1
    }

    if [[ -f "${target}" ]]; then
        grep -Eq \
            '^[[:space:]]*include[[:space:]]+"?/usr/share/nano/\*[.]nanorc"?[[:space:]]*(#.*)?$' \
            "${target}" && include_present=true
        grep -Eq \
            '^[[:space:]]*set[[:space:]]+linenumbers[[:space:]]*(#.*)?$' \
            "${target}" && linenumbers_present=true
    fi

    if [[ "${include_present}" == true && "${linenumbers_present}" == true ]]; then
        if ! chown "${owner}:${group}" -- "${target}" ||
            ! chmod 0644 -- "${target}"; then
            return 1
        fi
        printf 'Nano configuration is already current: %s\n' "${target}"
        return 0
    fi

    temporary="$(mktemp -- "${target_dir}/.nanorc.XXXXXX")"
    {
        if [[ -f "${target}" && -s "${target}" ]]; then
            cat -- "${target}"
            printf '\n'
        fi
        printf '# Managed additions from linux-scripts init.\n'
        [[ "${include_present}" == true ]] ||
            printf 'include "/usr/share/nano/*.nanorc"\n'
        [[ "${linenumbers_present}" == true ]] ||
            printf 'set linenumbers\n'
    } >"${temporary}"

    if ! chmod 0644 -- "${temporary}" ||
        ! chown "${owner}:${group}" -- "${temporary}" ||
        ! mv -f -- "${temporary}" "${target}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    printf 'Nano configuration updated: %s\n' "${target}"
}

configureNano() {
    local user_home="${1:-${HOME_USER_D}}"
    local root_home="${2:-${HOME_ROOT_D}}"
    local user_group

    isNormalUser "${CONFIG_USER}" || {
        printf 'CONFIG_USER must name an existing non-root user\n' >&2
        return 1
    }
    checkCommand nano || return
    compgen -G '/usr/share/nano/*.nanorc' >/dev/null || {
        printf 'No Nano syntax definitions found under /usr/share/nano\n' >&2
        return 1
    }
    user_group="$(id -gn -- "${CONFIG_USER}")" || return

    printf '\nConfiguring GNU nano for %s and root\n' "${CONFIG_USER}"
    configureNanoFile "${user_home}/.nanorc" \
        "${CONFIG_USER}" "${user_group}" || return
    configureNanoFile "${root_home}/.nanorc" root root
}
