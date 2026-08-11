#!/usr/bin/env bash

# Provisioning Module: SSH Authorized Keys
# Version: 3.0.0
# Updated: 2026-08-09
# Validates and atomically installs one optional public key for root and the
# provisioned user. Existing authorized_keys entries are preserved.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154,SC2310

validateSSHPublicKey() {
    local public_key="$1"
    local owner="$2"

    [[ -n "${public_key}" ]] || return 0
    if ! printf '%s\n' "${public_key}" |
        ssh-keygen -l -f - >/dev/null 2>&1; then
        printf 'Invalid SSH public key configured for %s\n' "${owner}" >&2
        return 1
    fi
}

validateSSHKeyConfiguration() {
    command -v ssh-keygen >/dev/null 2>&1 || {
        printf 'ssh-keygen command not found\n' >&2
        return 1
    }
    [[ -n "${CONFIG_SSH_KEY_USER:-}" || -n "${CONFIG_SSH_KEY_ROOT:-}" ]] || {
        printf 'At least one SSH public key must be configured\n' >&2
        return 1
    }

    validateSSHPublicKey "${CONFIG_SSH_KEY_USER:-}" "${CONFIG_USER}" || return
    validateSSHPublicKey "${CONFIG_SSH_KEY_ROOT:-}" root
}

installSSHPublicKey() {
    local public_key="$1"
    local ssh_dir="$2"
    local owner="$3"
    local group="$4"
    local destination="${ssh_dir}/authorized_keys"
    local temporary

    [[ -n "${public_key}" ]] || return 0
    [[ ! -L "${ssh_dir}" && ! -L "${destination}" ]] || {
        printf 'Refusing symbolic SSH path for %s\n' "${owner}" >&2
        return 1
    }

    install -d -o "${owner}" -g "${group}" -m 0700 -- "${ssh_dir}" || return
    if [[ -e "${destination}" ]]; then
        [[ -f "${destination}" ]] || {
            printf 'authorized_keys is not a regular file: %s\n' \
                "${destination}" >&2
            return 1
        }
        if grep -qxF -- "${public_key}" "${destination}"; then
            chown "${owner}:${group}" "${destination}" || return
            chmod 0600 -- "${destination}" || return
            return 0
        fi
    fi

    temporary="$(mktemp -- "${ssh_dir}/.authorized_keys.XXXXXX")" || return
    if [[ -e "${destination}" ]]; then
        if ! awk '1' "${destination}" >"${temporary}"; then
            rm -f -- "${temporary}"
            return 1
        fi
    fi
    if ! printf '%s\n' "${public_key}" >>"${temporary}" ||
        ! install -o "${owner}" -g "${group}" -m 0600 \
            -- "${temporary}" "${destination}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    rm -f -- "${temporary}"
}

addSSHKeys() {
    local user_home="${1:-${HOME_USER_D}}"
    local root_home="${2:-${HOME_ROOT_D}}"
    local user_group

    validateSSHKeyConfiguration || return
    user_group="$(id -gn -- "${CONFIG_USER}")" || return

    installSSHPublicKey "${CONFIG_SSH_KEY_USER:-}" \
        "${user_home}/.ssh" "${CONFIG_USER}" "${user_group}" || return
    installSSHPublicKey "${CONFIG_SSH_KEY_ROOT:-}" \
        "${root_home}/.ssh" root root || return
    printf 'SSH public keys installed\n'
}
