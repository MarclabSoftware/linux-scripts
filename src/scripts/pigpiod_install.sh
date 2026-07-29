#!/usr/bin/env bash

# Arch Linux pigpio Installer
# Version: 2.0.0
# Updated: 2026-07-29
#
# Builds the pigpio AUR package as an unprivileged user and installs a systemd
# drop-in for the pigpiod sampling interval. Valid pigpiod sample rates are
# 1, 2, 4, 5, 8 and 10 microseconds.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly AUR_URL="https://aur.archlinux.org/pigpio.git"

die() {
    printf 'pigpiod_install: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command not found: $1"
}

AUR_CACHE_DIR="${PIGPIOD_AUR_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/aur-builds}"
SAMPLE_INTERVAL="${PIGPIOD_SAMPLE_INTERVAL_US:-10}"

while (($# > 0)); do
    case "$1" in
        --cache-dir)
            (($# >= 2)) || die "--cache-dir requires a value"
            AUR_CACHE_DIR="$2"
            shift
            ;;
        --sample-interval)
            (($# >= 2)) || die "--sample-interval requires a value"
            SAMPLE_INTERVAL="$2"
            shift
            ;;
        --help | -h)
            printf '%s\n' \
                'Usage: pigpiod_install.sh [OPTIONS]' \
                '  --cache-dir PATH          AUR source cache' \
                '  --sample-interval NUMBER  1, 2, 4, 5, 8 or 10 microseconds'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

((EUID != 0)) || die "run this script as an unprivileged user"
[[ "${AUR_CACHE_DIR}" == /* ]] || die "cache directory must be an absolute path"
case "${SAMPLE_INTERVAL}" in
    1 | 2 | 4 | 5 | 8 | 10) ;;
    *) die "sample interval must be 1, 2, 4, 5, 8 or 10 microseconds" ;;
esac

for command_name in git makepkg sudo systemctl; do
    require_command "${command_name}"
done

package_dir="${AUR_CACHE_DIR}/pigpio"
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

drop_in="$(mktemp)"
trap 'rm -f -- "${drop_in}"' EXIT
cat >"${drop_in}" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/pigpiod -s ${SAMPLE_INTERVAL}
EOF

sudo install -D -m 0644 -- "${drop_in}" \
    /etc/systemd/system/pigpiod.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable --now pigpiod.service
printf 'pigpiod installed with a %s microsecond sample interval\n' "${SAMPLE_INTERVAL}"
