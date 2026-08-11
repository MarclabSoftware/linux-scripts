#!/usr/bin/env bash

# Provisioning module: package cleanup.
#
# Removes orphaned packages and empties downloaded package caches after the
# phase-one update. Pacman hosts also clear Yay's per-user AUR build cache when
# Yay is installed. Configuration and shared helpers are injected by init.sh.
#
# shellcheck disable=SC2154,SC2310

cleanup_pacman_packages() {
    local -a orphaned_packages=()
    local yay_path

    checkCommand pacman
    checkCommand paccache

    printf '\nRemoving orphaned Pacman packages\n'
    mapfile -t orphaned_packages < <(pacman -Qtdq 2>/dev/null || true)
    if ((${#orphaned_packages[@]} > 0)); then
        pacman -Rns --noconfirm "${orphaned_packages[@]}"
    fi

    printf '\nEmptying the Pacman package cache\n'
    paccache -rk0

    if yay_path="$(command -v yay 2>/dev/null)"; then
        checkCommand sudo
        printf '\nEmptying the Yay AUR build cache for %s\n' "${CONFIG_USER}"
        sudo -H -u "${CONFIG_USER}" -- \
            "${yay_path}" -Sc --aur --noconfirm
    fi
}

cleanup_apt_packages() {
    checkCommand apt-get

    printf '\nRemoving orphaned Debian packages\n'
    apt-get --yes autoremove

    printf '\nEmptying the APT package cache\n'
    apt-get clean
}

cleanupPackages() {
    local package_manager

    package_manager="$(selected_package_manager)"
    case "${package_manager}" in
        pacman)
            cleanup_pacman_packages
            ;;
        apt)
            cleanup_apt_packages
            ;;
        *)
            printf 'Unsupported package manager: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac
}
