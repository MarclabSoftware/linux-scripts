#!/usr/bin/env bash

# Provisioning module: virtual memory and zram.
#
# The kernel remains responsible for watermarks, free-memory reserves and
# writeback policy. This module only configures the two swap-policy knobs whose
# useful values depend on the backing device, plus native zram-generator.
#
# shellcheck disable=SC2154

validateMemoryConfiguration() {
    local compression="${CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM:-}"
    local overcommit_memory="${CONFIG_MEMORY_OVERCOMMIT_MEMORY:-}"
    local page_cluster="${CONFIG_MEMORY_PAGE_CLUSTER:-}"
    local swappiness="${CONFIG_MEMORY_SWAPPINESS:-}"
    local zram_enabled="${CONFIG_MEMORY_ZRAM_ENABLED:-}"
    local zram_size="${CONFIG_MEMORY_ZRAM_SIZE:-}"

    if ! [[ "${swappiness}" =~ ^[0-9]+$ ]] ||
        ((10#${swappiness} > 200)); then
        printf 'CONFIG_MEMORY_SWAPPINESS must be an integer from 0 to 200\n' >&2
        return 1
    fi
    if ! [[ "${page_cluster}" =~ ^[0-9]+$ ]] ||
        ((10#${page_cluster} > 31)); then
        printf 'CONFIG_MEMORY_PAGE_CLUSTER must be an integer from 0 to 31\n' >&2
        return 1
    fi
    [[ -z "${overcommit_memory}" || "${overcommit_memory}" =~ ^[012]$ ]] || {
        printf 'CONFIG_MEMORY_OVERCOMMIT_MEMORY must be empty, 0, 1 or 2\n' >&2
        return 1
    }
    case "${zram_enabled}" in
        true | false) ;;
        *)
            printf 'CONFIG_MEMORY_ZRAM_ENABLED must be true or false\n' >&2
            return 1
            ;;
    esac

    [[ "${zram_enabled}" == true ]] || return 0

    [[ -n "${zram_size}" &&
        "${zram_size}" != *$'\n'* &&
        "${zram_size}" != *$'\r'* &&
        "${zram_size}" =~ ^[[:alnum:]_+*/%().,[:space:]-]+$ ]] || {
        printf 'CONFIG_MEMORY_ZRAM_SIZE is not a safe zram-size expression\n' >&2
        return 1
    }
    [[ -z "${compression}" ||
        "${compression}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || {
        printf 'CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM must be empty or an algorithm name\n' >&2
        return 1
    }
}

# Configure memory policy below an optional test root. Live zram devices are
# intentionally not recreated: the mandatory phase-one reboot applies them
# without moving active pages or temporarily removing swap.
configureMemory() {
    local root="${1:-}"
    local compression="${CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM:-}"
    local overcommit_memory="${CONFIG_MEMORY_OVERCOMMIT_MEMORY:-}"
    local page_cluster="${CONFIG_MEMORY_PAGE_CLUSTER:-}"
    local swappiness="${CONFIG_MEMORY_SWAPPINESS:-}"
    local zram_enabled="${CONFIG_MEMORY_ZRAM_ENABLED:-}"
    local zram_size="${CONFIG_MEMORY_ZRAM_SIZE:-}"
    local sysctl_conf
    local legacy_sysctl_conf
    local zram_conf
    local zswap_unit
    local zram_setup_dropin
    local -a sysctl_lines=(
        '# Managed by linux-scripts init.'
        "vm.swappiness = ${swappiness}"
        "vm.page-cluster = ${page_cluster}"
    )
    local -a zram_lines=()

    [[ -z "${root}" || "${root}" == /* ]] || {
        printf 'configureMemory: test root must be absolute\n' >&2
        return 2
    }
    root="${root%/}"
    sysctl_conf="${root}/etc/sysctl.d/90-linux-scripts-memory.conf"
    legacy_sysctl_conf="${root}/etc/sysctl.d/swappiness.conf"
    zram_conf="${root}/etc/systemd/zram-generator.conf.d/90-linux-scripts.conf"
    zswap_unit="${root}/etc/systemd/system/linux-scripts-zswap-disable.service"
    zram_setup_dropin="${root}/etc/systemd/system/systemd-zram-setup@.service.d/90-linux-scripts-zswap.conf"

    validateMemoryConfiguration
    checkCommand systemctl
    checkCommand sysctl

    if [[ -n "${overcommit_memory}" ]]; then
        sysctl_lines+=("vm.overcommit_memory = ${overcommit_memory}")
    fi
    printf '%s\n' "${sysctl_lines[@]}" |
        installConfigFile "${sysctl_conf}"
    rm -f -- "${legacy_sysctl_conf}"
    sysctl --load="${sysctl_conf}"

    if [[ "${zram_enabled}" == true ]]; then
        zram_lines=(
            '# Managed by linux-scripts init.'
            '[zram0]'
            "zram-size = ${zram_size}"
        )
        if [[ -n "${compression}" ]]; then
            zram_lines+=("compression-algorithm = ${compression}")
        fi
        zram_lines+=('swap-priority = 100')
        printf '%s\n' "${zram_lines[@]}" |
            installConfigFile "${zram_conf}"

        printf '%s\n' \
            '[Unit]' \
            'Description=Disable zswap before zram setup' \
            'DefaultDependencies=no' \
            'ConditionPathExists=/sys/module/zswap/parameters/enabled' \
            '' \
            '[Service]' \
            'Type=oneshot' \
            "ExecStart=/bin/sh -c 'printf N > /sys/module/zswap/parameters/enabled'" \
            'RemainAfterExit=yes' |
            installConfigFile "${zswap_unit}"

        printf '%s\n' \
            '[Unit]' \
            'Requires=linux-scripts-zswap-disable.service' \
            'After=linux-scripts-zswap-disable.service' |
            installConfigFile "${zram_setup_dropin}"

        # Raspberry Pi OS commonly manages a disk-backed swap file with this
        # unit. Keep the file for rollback, but let zram be the only active
        # swap provider after the required reboot.
        if systemctl cat dphys-swapfile.service >/dev/null 2>&1; then
            systemctl disable dphys-swapfile.service
        fi
    else
        rm -f -- "${zram_conf}" "${zswap_unit}" "${zram_setup_dropin}"
    fi

    systemctl daemon-reload
    printf 'Memory configuration installed; reboot applies zram changes\n'
}
