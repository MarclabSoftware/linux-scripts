#!/usr/bin/env bash

# Arch Linux Argon One Driver Installer
# Version: 2.0.0
# Updated: 2026-07-29
#
# Builds and installs the argonone-c-git AUR package as an unprivileged user.
# The source checkout is kept in the user's cache so subsequent runs only need
# a fast-forward update.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly AUR_URL="https://aur.archlinux.org/argonone-c-git.git"

die() {
    printf 'argonone_install: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command not found: $1"
}

AUR_CACHE_DIR="${ARGONONE_AUR_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/aur-builds}"

while (($# > 0)); do
    case "$1" in
        --cache-dir)
            (($# >= 2)) || die "--cache-dir requires a value"
            AUR_CACHE_DIR="$2"
            shift
            ;;
        --help | -h)
            printf '%s\n' \
                'Usage: argonone_install.sh [OPTIONS]' \
                '  --cache-dir PATH  AUR source cache'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

((EUID != 0)) || die "run this script as an unprivileged user"
[[ "${AUR_CACHE_DIR}" == /* ]] || die "cache directory must be an absolute path"

for command_name in git makepkg; do
    require_command "${command_name}"
done

package_dir="${AUR_CACHE_DIR}/argonone-c-git"
mkdir -p -- "${AUR_CACHE_DIR}"
if [[ -d "${package_dir}/.git" ]]; then
    git -C "${package_dir}" pull --ff-only
elif [[ -e "${package_dir}" ]]; then
    die "package path exists but is not a Git checkout: ${package_dir}"
else
    git clone -- "${AUR_URL}" "${package_dir}"
fi

(
    cd -- "${package_dir}"
    makepkg --clean --force --install --syncdeps
)
