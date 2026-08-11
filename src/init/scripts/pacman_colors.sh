#!/usr/bin/env bash

# Provisioning module: Pacman colors.
#
# Enables Pacman's Color option and ILoveCandy progress bar. The optional first
# argument selects a different pacman.conf, primarily for validation or chroots.
# The default remains the system configuration at /etc/pacman.conf.

setPacmanColors() {
    local pacman_conf_f="${1:-/etc/pacman.conf}"
    local backup_f="${pacman_conf_f}.bak"

    printf '\nEnabling Pacman colored output\n'

    if [[ ! -f "${pacman_conf_f}" ]]; then
        printf '%s not found, cannot continue\n' "${pacman_conf_f}" >&2
        return 1
    fi

    if grep -qxF 'Color' "${pacman_conf_f}" &&
        grep -qxF 'ILoveCandy' "${pacman_conf_f}"; then
        printf 'Pacman colored output is already enabled\n'
        return 0
    fi

    if ! grep -qxF 'Color' "${pacman_conf_f}" &&
        ! grep -qxF '#Color' "${pacman_conf_f}"; then
        printf 'Cannot find the Pacman Color option in %s\n' \
            "${pacman_conf_f}" >&2
        return 1
    fi

    # Preserve the original configuration only once. Re-running provisioning
    # must not replace that recovery copy with an already modified file.
    if [[ ! -e "${backup_f}" ]]; then
        cp -a -- "${pacman_conf_f}" "${backup_f}"
        printf 'Original Pacman configuration backed up at %s\n' "${backup_f}"
    fi

    sed -i 's/^#Color$/Color/' "${pacman_conf_f}"
    grep -qxF 'ILoveCandy' "${pacman_conf_f}" ||
        sed -i '/^Color$/a ILoveCandy' "${pacman_conf_f}"

    if ! grep -qxF 'Color' "${pacman_conf_f}" ||
        ! grep -qxF 'ILoveCandy' "${pacman_conf_f}"; then
        printf 'Unable to enable Pacman colored output in %s\n' \
            "${pacman_conf_f}" >&2
        return 1
    fi
    printf 'Pacman colored output enabled\n'
}
