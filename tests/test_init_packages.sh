#!/usr/bin/env bash

# Validate package-list parsing and idempotent Pacman color configuration.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# shellcheck source=../src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=../src/init/scripts/system_update.sh
. "${REPO_ROOT}/src/init/scripts/system_update.sh"
# shellcheck source=../src/init/scripts/pacman_colors.sh
. "${REPO_ROOT}/src/init/scripts/pacman_colors.sh"

declare -a packages=()
parse_package_list "git, htop,pacman-contrib" packages
[[ "${packages[*]}" == "git htop pacman-contrib" ]]

CONFIG_INIT_MEMORY_CONFIGURE=true
CONFIG_MEMORY_ZRAM_ENABLED=true
zram_package="$(zram_package_name pacman)"
[[ "${zram_package}" == "zram-generator" ]]
zram_package="$(zram_package_name apt)"
[[ "${zram_package}" == "systemd-zram-generator" ]]

CONFIG_MEMORY_ZRAM_ENABLED=false
zram_package="$(zram_package_name pacman)"
[[ -z "${zram_package}" ]]

CONFIG_INIT_NTP_CUSTOMIZATION=true
CONFIG_NTP_BACKEND="chrony"
ntp_package="$(ntp_package_name pacman)"
[[ "${ntp_package}" == "chrony" ]]
ntp_package="$(ntp_package_name apt)"
[[ "${ntp_package}" == "chrony" ]]

CONFIG_NTP_BACKEND="timesyncd"
ntp_package="$(ntp_package_name pacman)"
[[ -z "${ntp_package}" ]]
ntp_package="$(ntp_package_name apt)"
[[ "${ntp_package}" == "systemd-timesyncd" ]]

CONFIG_INIT_NTP_CUSTOMIZATION=false

set +e
parse_package_list "git, ,htop" packages 2>/dev/null
parse_status=$?
set -e
if ((parse_status == 0)); then
    printf 'empty package-list entry was accepted\n' >&2
    exit 1
fi

test_dir="$(mktemp -d)"
readonly test_dir
trap 'rm -rf -- "${test_dir}"' EXIT

# A minimal Arch host may not have sudo before the system transaction. The
# Pacman mock makes it available only after recording the requested packages.
arch_update_log="${test_dir}/arch-update.log"
pacman() {
    printf '%s\n' "$*" >"${arch_update_log}"
    sudo() {
        return 0
    }
}
pacdiff() {
    [[ "$1" == --output ]]
}
CONFIG_PACKAGE_MANAGER="pacman"
CONFIG_PACMAN_PACKAGES="git"
(
    # Hide host-installed Yay and sudo to model a minimal Arch installation.
    # shellcheck disable=SC2123
    PATH="${test_dir}/empty"
    updateSystem
    sudo true
) >/dev/null
grep -Fx -- '-Syu --needed sudo pacman-contrib git' \
    "${arch_update_log}" >/dev/null

# Configure the official Docker repository entirely below the test directory.
docker_os_release="${test_dir}/os-release"
docker_key="${test_dir}/etc/apt/keyrings/docker.asc"
docker_source="${test_dir}/etc/apt/sources.list.d/docker.sources"
docker_legacy_source="${test_dir}/etc/apt/sources.list.d/docker.list"
printf 'ID=debian\nVERSION_CODENAME=bookworm\n' >"${docker_os_release}"
mkdir -p -- "${docker_legacy_source%/*}"
printf '%s\n' \
    'deb [arch=arm64] https://download.docker.com/linux/debian bookworm stable' \
    >"${docker_legacy_source}"
curl() {
    local output_file=""

    while (($# > 0)); do
        case "$1" in
            -o)
                output_file="$2"
                shift 2
                ;;
            -*)
                shift
                ;;
            *)
                [[ "$1" == https://download.docker.com/linux/debian/gpg ]] ||
                    return 2
                shift
                ;;
        esac
    done
    [[ -n "${output_file}" ]] || return 2
    printf '%s\n' \
        '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
        'test-key' \
        '-----END PGP PUBLIC KEY BLOCK-----' >"${output_file}"
}
dpkg() {
    [[ "$1" == --print-architecture ]] || return 2
    printf 'arm64\n'
}
configure_docker_apt_repository "${docker_os_release}" "${docker_key}" \
    "${docker_source}" "${docker_legacy_source}" >/dev/null
grep -Fx 'URIs: https://download.docker.com/linux/debian' \
    "${docker_source}" >/dev/null
grep -Fx 'Suites: bookworm' "${docker_source}" >/dev/null
grep -Fx 'Architectures: arm64' "${docker_source}" >/dev/null
grep -Fx "Signed-By: ${docker_key}" "${docker_source}" >/dev/null
docker_key_mode="$(stat -c '%a' "${docker_key}")"
docker_source_mode="$(stat -c '%a' "${docker_source}")"
[[ "${docker_key_mode}" == 644 ]]
[[ "${docker_source_mode}" == 644 ]]
[[ ! -e "${docker_legacy_source}" ]]

printf 'deb https://packages.example.invalid stable main\n' \
    >"${docker_legacy_source}"
set +e
migrate_legacy_docker_apt_source "${docker_legacy_source}" >/dev/null 2>&1
legacy_status=$?
set -e
if ((legacy_status == 0)); then
    printf 'customized legacy Docker source was removed\n' >&2
    exit 1
fi
[[ -f "${docker_legacy_source}" ]]

pacman_conf="${test_dir}/pacman.conf"
printf '[options]\n#Color\n' >"${pacman_conf}"

setPacmanColors "${pacman_conf}" >/dev/null
grep -qxF 'Color' "${pacman_conf}"
grep -qxF 'ILoveCandy' "${pacman_conf}"
grep -qxF '#Color' "${pacman_conf}.bak"

setPacmanColors "${pacman_conf}" >/dev/null
color_count="$(grep -cFx 'Color' "${pacman_conf}")"
candy_count="$(grep -cFx 'ILoveCandy' "${pacman_conf}")"
[[ "${color_count}" == 1 ]]
[[ "${candy_count}" == 1 ]]
grep -qxF '#Color' "${pacman_conf}.bak"

missing_color_conf="${test_dir}/missing-color.conf"
printf '[options]\n' >"${missing_color_conf}"
set +e
setPacmanColors "${missing_color_conf}" >/dev/null 2>&1
color_status=$?
set -e
if ((color_status == 0)); then
    printf 'Pacman colors accepted a configuration without Color\n' >&2
    exit 1
fi
[[ ! -e "${missing_color_conf}.bak" ]]

printf 'init package tests passed\n'
