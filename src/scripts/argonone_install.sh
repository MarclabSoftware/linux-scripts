#!/usr/bin/env bash

# Vars
AUR_PKGS_D="/home/${USER}/aur_packages"
GIT_URL="https://aur.archlinux.org/argonone-c-git.git"
PKG_D="${AUR_PKGS_D}/$(basename "${GIT_URL}" .git)"

# Main
if [[ "${EUID}" -eq 0 ]]; then
    echo "Please run as normal user"
    exit 1
fi

[[ -d "${AUR_PKGS_D}" ]] || mkdir -p "${AUR_PKGS_D}"
cd "${AUR_PKGS_D}" || exit 1

if [[ -d "${PKG_D}" ]]; then
    cd "${PKG_D}" || exit 2
    git pull
else
    git clone "${GIT_URL}"
    cd "${PKG_D}" || exit 3
fi

makepkg -cfsi

exit 0
