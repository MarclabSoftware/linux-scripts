#!/usr/bin/env bash

# Provisioning module: passwordless sudo.
#
# Installs one repository-owned sudoers drop-in atomically. The candidate and
# complete sudoers policy are validated with visudo; an existing managed file
# is restored if full-policy validation fails.
#
# Configuration and shared helpers are provided by init.sh.
# shellcheck disable=SC2154

enablePasswordlessSudo() {
    local sudoers_dir="${1:-/etc/sudoers.d}"
    local sudoers_file="${sudoers_dir}/90-linux-scripts-nopasswd"
    local backup=""
    local candidate

    [[ "${sudoers_dir}" == /* ]] || {
        printf 'enablePasswordlessSudo: sudoers directory must be absolute\n' >&2
        return 2
    }
    isNormalUser "${CONFIG_USER}" || {
        printf 'CONFIG_USER must name an existing non-root user\n' >&2
        return 1
    }
    checkCommand visudo
    [[ ! -L "${sudoers_file}" ]] || {
        printf 'Refusing symbolic-link sudoers target: %s\n' \
            "${sudoers_file}" >&2
        return 1
    }

    if [[ ! -d "${sudoers_dir}" ]]; then
        install -d -o root -g root -m 0750 -- "${sudoers_dir}"
    fi
    candidate="$(mktemp -- "${sudoers_dir}/.linux-scripts-nopasswd.XXXXXX")"
    if ! printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' \
        "${CONFIG_USER}" >"${candidate}" ||
        ! chown root:root -- "${candidate}" ||
        ! chmod 0440 -- "${candidate}" ||
        ! visudo -cf "${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi

    if [[ -e "${sudoers_file}" ]]; then
        backup="$(mktemp -- "${sudoers_dir}/.linux-scripts-nopasswd-backup.XXXXXX")"
        if ! cp -a -- "${sudoers_file}" "${backup}"; then
            rm -f -- "${candidate}" "${backup}"
            return 1
        fi
    fi

    if cmp -s -- "${candidate}" "${sudoers_file}"; then
        rm -f -- "${candidate}"
        chown root:root -- "${sudoers_file}"
        chmod 0440 -- "${sudoers_file}"
    elif ! mv -f -- "${candidate}" "${sudoers_file}"; then
        rm -f -- "${candidate}" "${backup}"
        return 1
    fi

    if ! visudo -c; then
        if [[ -n "${backup}" ]]; then
            mv -f -- "${backup}" "${sudoers_file}"
        else
            rm -f -- "${sudoers_file}"
        fi
        printf 'Full sudoers validation failed; previous policy restored\n' >&2
        return 1
    fi

    rm -f -- "${backup}"
    printf 'Passwordless sudo enabled through %s\n' "${sudoers_file}"
}
