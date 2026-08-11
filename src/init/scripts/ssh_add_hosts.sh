#!/usr/bin/env bash

# Provisioning Module: SSH Known Hosts
# Version: 3.0.0
# Updated: 2026-08-09
# Adds administrator-verified entries to the system-wide known_hosts file.
# Per-user trust databases remain untouched.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154,SC2310

validateSSHKnownHostsConfiguration() {
    local source_file

    checkConfig "CONFIG_SSH_KNOWN_HOSTS_FILE" || return 1
    source_file="${CONFIG_SSH_KNOWN_HOSTS_FILE}"
    [[ "${source_file}" == /* && -r "${source_file}" ]] || {
        printf '%s\n' \
            'CONFIG_SSH_KNOWN_HOSTS_FILE must be an absolute readable file' >&2
        return 1
    }
    command -v ssh-keygen >/dev/null 2>&1 || {
        printf 'ssh-keygen command not found\n' >&2
        return 1
    }
    ssh-keygen -l -f "${source_file}" >/dev/null 2>&1 || {
        printf 'Invalid SSH known_hosts file: %s\n' "${source_file}" >&2
        return 1
    }
}

addSSHHosts() {
    local target_file="${1:-/etc/ssh/ssh_known_hosts}"
    local source_file="${CONFIG_SSH_KNOWN_HOSTS_FILE}"
    local merged_file

    validateSSHKnownHostsConfiguration || return
    if [[ -e "${target_file}" ]]; then
        merged_file="$(mktemp)" || return
        if ! awk '!seen[$0]++' \
            "${target_file}" "${source_file}" >"${merged_file}" ||
            ! installConfigFile "${target_file}" <"${merged_file}"; then
            rm -f -- "${merged_file}"
            return 1
        fi
        rm -f -- "${merged_file}"
    else
        installConfigFile "${target_file}" <"${source_file}" || return
    fi

    printf 'Verified system-wide SSH known-host entries installed\n'
}
