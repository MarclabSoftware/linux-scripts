#!/usr/bin/env bash

# Provisioning module: complete system update.
#
# Official repository packages are upgraded and configured packages are
# installed before host configuration begins. On Pacman systems, Yay is then
# used as the managed non-root user when it is already installed so AUR
# packages are not left behind. Package-manager configuration conflicts stop
# provisioning before any host configuration is changed.
#
# shellcheck disable=SC2154

detect_package_manager() (
    local ID=""
    local ID_LIKE=""

    if [[ -r /etc/os-release ]]; then
        # os-release is a trusted system file. Read only the identifiers needed
        # for selecting the native package manager.
        # shellcheck source=/dev/null
        . /etc/os-release
    fi

    case " ${ID} ${ID_LIKE} " in
        *" arch "* | *" cachyos "* | *" archarm "*)
            printf 'pacman\n'
            return 0
            ;;
        *" debian "* | *" raspbian "*)
            printf 'apt\n'
            return 0
            ;;
        *) ;;
    esac

    if command -v pacman >/dev/null 2>&1 &&
        ! command -v apt-get >/dev/null 2>&1; then
        printf 'pacman\n'
    elif command -v apt-get >/dev/null 2>&1 &&
        ! command -v pacman >/dev/null 2>&1; then
        printf 'apt\n'
    else
        printf 'Cannot determine the system package manager\n' >&2
        return 1
    fi
)

parse_package_list() {
    local package_list="$1"
    local output_name="$2"
    local -n output_ref="${output_name}"
    local -a raw_packages=()
    local package

    output_ref=()
    [[ -n "${package_list}" ]] || return 0

    IFS=, read -r -a raw_packages <<<"${package_list}"
    for package in "${raw_packages[@]}"; do
        # Accept readable lists such as "git, htop" without passing whitespace
        # as part of a package name.
        package="${package#"${package%%[![:space:]]*}"}"
        package="${package%"${package##*[![:space:]]}"}"
        [[ -n "${package}" ]] || {
            printf 'Package lists must not contain empty entries\n' >&2
            return 1
        }
        output_ref+=("${package}")
    done
}

zram_package_name() {
    local package_manager="$1"

    [[ "${CONFIG_INIT_MEMORY_CONFIGURE:-false}" == true &&
        "${CONFIG_MEMORY_ZRAM_ENABLED:-false}" == true ]] || return 0

    case "${package_manager}" in
        pacman)
            printf 'zram-generator\n'
            ;;
        apt)
            printf 'systemd-zram-generator\n'
            ;;
        *)
            printf 'Unsupported package manager for zram: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac
}

ntp_package_name() {
    local package_manager="$1"

    [[ "${CONFIG_INIT_NTP_CUSTOMIZATION:-false}" == true ]] || return 0

    case "${CONFIG_NTP_BACKEND:-}:${package_manager}" in
        chrony:pacman | chrony:apt)
            printf 'chrony\n'
            ;;
        timesyncd:apt)
            printf 'systemd-timesyncd\n'
            ;;
        timesyncd:pacman)
            # systemd-timesyncd is included in Arch's systemd package.
            ;;
        *)
            printf 'Unsupported NTP backend/package manager combination: %s/%s\n' \
                "${CONFIG_NTP_BACKEND:-<unset>}" "${package_manager}" >&2
            return 1
            ;;
    esac
}

check_arch_config_updates() {
    local pending_files

    pending_files="$(pacdiff --output)" || {
        printf 'Unable to check for pacnew/pacsave files\n' >&2
        return 1
    }
    if [[ -n "${pending_files}" ]]; then
        printf 'Resolve these package configuration files, then run init again:\n%s\n' \
            "${pending_files}" >&2
        return 1
    fi
}

update_arch_system() {
    local -a packages=()
    local ntp_package yay_path zram_package

    printf '\nUpdating all official Arch packages\n'

    # sudo is required by Yay and later user administration; pacman-contrib
    # provides the pacdiff safety gate. Bootstrap both in the complete upgrade
    # transaction so a fresh minimal Arch installation needs no preinstalled
    # sudo and no partial upgrade.
    parse_package_list "${CONFIG_PACMAN_PACKAGES:-}" packages
    zram_package="$(zram_package_name pacman)"
    [[ -z "${zram_package}" ]] || packages+=("${zram_package}")
    ntp_package="$(ntp_package_name pacman)"
    [[ -z "${ntp_package}" ]] || packages+=("${ntp_package}")
    pacman -Syu --needed sudo pacman-contrib "${packages[@]}"
    checkCommand sudo

    if yay_path="$(command -v yay 2>/dev/null)"; then
        printf '\nUpdating installed AUR packages with Yay\n'
        sudo -H -u "${CONFIG_USER}" -- "${yay_path}" -Syu --aur
    fi

    check_arch_config_updates
}

docker_debian_codename() (
    if (($# != 1)) || [[ ! -r "$1" ]]; then
        printf 'docker_debian_codename: expected a readable os-release file\n' >&2
        return 2
    fi

    local ID=""
    local VERSION_CODENAME=""

    # Read only the distribution identifiers from the trusted system file.
    # shellcheck source=/dev/null
    . "$1"
    case "${ID}" in
        debian | raspbian) ;;
        *)
            printf 'Docker APT provisioning supports Debian and Raspberry Pi OS only\n' >&2
            return 1
            ;;
    esac
    [[ "${VERSION_CODENAME}" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
        printf 'Invalid or missing Debian VERSION_CODENAME\n' >&2
        return 1
    }
    printf '%s\n' "${VERSION_CODENAME}"
)

render_docker_apt_source() {
    if (($# != 3)) ||
        [[ ! "$1" =~ ^[a-z0-9][a-z0-9.-]*$ ]] ||
        [[ ! "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        [[ "$3" != /* || "$3" == *[[:space:]]* ]]; then
        printf 'render_docker_apt_source: expected CODENAME ARCH ABSOLUTE_KEY_PATH\n' >&2
        return 2
    fi

    cat <<EOF
# Managed by linux-scripts. Local changes will be replaced.
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $1
Components: stable
Architectures: $2
Signed-By: $3
EOF
}

migrate_legacy_docker_apt_source() {
    if (($# != 1)) || [[ "$1" != /* ]]; then
        printf 'migrate_legacy_docker_apt_source: expected an absolute path\n' >&2
        return 2
    fi

    local legacy_source="$1"

    [[ -e "${legacy_source}" || -L "${legacy_source}" ]] || return 0
    [[ -f "${legacy_source}" && ! -L "${legacy_source}" ]] || {
        printf 'Legacy Docker APT source is not a regular file: %s\n' \
            "${legacy_source}" >&2
        return 1
    }
    awk '
        /^[[:space:]]*($|#)/ { next }
        /^[[:space:]]*deb[[:space:]].*https:\/\/download\.docker\.com\/linux\/(debian|raspbian)([[:space:]]|$)/ { next }
        { exit 1 }
    ' "${legacy_source}" || {
        printf 'Refusing to remove a customized legacy Docker APT source: %s\n' \
            "${legacy_source}" >&2
        return 1
    }
    rm -f -- "${legacy_source}"
}

configure_docker_apt_repository() {
    if (($# != 4)); then
        printf 'configure_docker_apt_repository: expected four paths\n' >&2
        return 2
    fi

    local os_release="$1"
    local key_file="$2"
    local source_file="$3"
    local legacy_source="$4"
    local architecture codename path source_content temporary_key

    for path in "${key_file}" "${source_file}" "${legacy_source}"; do
        [[ "${path}" == /* ]] || {
            printf 'Docker APT paths must be absolute: %s\n' "${path}" >&2
            return 2
        }
    done

    codename="$(docker_debian_codename "${os_release}")" || return
    architecture="$(dpkg --print-architecture)" || return
    [[ "${architecture}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        printf 'Invalid Debian package architecture: %s\n' \
            "${architecture}" >&2
        return 1
    }
    source_content="$(
        render_docker_apt_source "${codename}" "${architecture}" \
            "${key_file}"
    )" || return

    checkCommand curl || return
    temporary_key="$(mktemp)" || return
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o "${temporary_key}" ||
        ! grep -qF -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
            "${temporary_key}" ||
        ! grep -qF -- '-----END PGP PUBLIC KEY BLOCK-----' \
            "${temporary_key}"; then
        rm -f -- "${temporary_key}"
        printf 'Unable to download a valid Docker repository key\n' >&2
        return 1
    fi
    if ! installConfigFile "${key_file}" <"${temporary_key}" ||
        ! installConfigFile "${source_file}" <<<"${source_content}"; then
        rm -f -- "${temporary_key}"
        return 1
    fi
    rm -f -- "${temporary_key}"
    migrate_legacy_docker_apt_source "${legacy_source}" || return
    printf 'Official Docker APT repository configured\n'
}

update_debian_system() {
    local -a packages=()
    local ntp_package zram_package

    printf '\nRefreshing APT package metadata\n'
    apt-get update

    printf '\nUpdating all Debian packages\n'
    apt-get dist-upgrade

    parse_package_list "${CONFIG_APT_PACKAGES:-}" packages
    zram_package="$(zram_package_name apt)"
    [[ -z "${zram_package}" ]] || packages+=("${zram_package}")
    ntp_package="$(ntp_package_name apt)"
    [[ -z "${ntp_package}" ]] || packages+=("${ntp_package}")
    if [[ "${CONFIG_INIT_SRV_DOCKER_ENABLE:-false}" == true ]]; then
        printf '\nInstalling Docker repository prerequisites\n'
        apt-get install -- ca-certificates curl
        checkCommand curl
        configure_docker_apt_repository \
            /etc/os-release \
            /etc/apt/keyrings/docker.asc \
            /etc/apt/sources.list.d/docker.sources \
            /etc/apt/sources.list.d/docker.list
        apt-get update
        packages+=(
            docker-ce
            docker-ce-cli
            containerd.io
            docker-buildx-plugin
            docker-compose-plugin
        )
    fi
    if ((${#packages[@]} > 0)); then
        printf '\nInstalling configured Debian packages\n'
        apt-get install -- "${packages[@]}"
    fi
}

check_debian_package_state() {
    local audit_output

    apt-get check

    audit_output="$(dpkg --audit)" || {
        printf 'Unable to audit the dpkg database\n' >&2
        return 1
    }
    if [[ -n "${audit_output}" ]]; then
        printf 'Resolve these dpkg issues, then run init again:\n%s\n' \
            "${audit_output}" >&2
        return 1
    fi
}

selected_package_manager() {
    local package_manager="${CONFIG_PACKAGE_MANAGER}"

    if [[ "${package_manager}" == auto ]]; then
        package_manager="$(detect_package_manager)"
    fi
    printf '%s\n' "${package_manager}"
}

checkPackageConfiguration() {
    local package_manager

    package_manager="$(selected_package_manager)"
    case "${package_manager}" in
        pacman)
            check_arch_config_updates
            ;;
        apt)
            check_debian_package_state
            ;;
        *)
            printf 'Unsupported package manager: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac
}

updateSystem() {
    local package_manager

    package_manager="$(selected_package_manager)"

    case "${package_manager}" in
        pacman)
            checkCommand pacman
            update_arch_system
            ;;
        apt)
            checkCommand apt-get
            checkCommand dpkg
            update_debian_system
            ;;
        *)
            printf 'Unsupported package manager: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac
}
