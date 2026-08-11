#!/usr/bin/env bash

# Provisioning module: Raspberry Pi boot firmware configuration.
#
# Host-specific settings are kept in a small managed fragment instead of
# editing individual properties in config.txt. This supports current and future
# firmware options without embedding board-specific assumptions in this repo.
#
# Configuration and shared helpers are provided by init.sh.
# shellcheck disable=SC2154

readonly RPI_MANAGED_BOOT_FRAGMENT="linux-scripts.txt"

validateRpiBootConfiguration() {
    local declaration
    local line

    declaration="$(declare -p CONFIG_RPI_BOOT_SETTINGS 2>/dev/null)" || {
        printf 'CONFIG_RPI_BOOT_SETTINGS must be an indexed Bash array\n' >&2
        return 1
    }
    [[ "${declaration}" == "declare -a "* ]] || {
        printf 'CONFIG_RPI_BOOT_SETTINGS must be an indexed Bash array\n' >&2
        return 1
    }
    ((${#CONFIG_RPI_BOOT_SETTINGS[@]} > 0)) || {
        printf 'CONFIG_RPI_BOOT_SETTINGS must contain at least one line\n' >&2
        return 1
    }

    for line in "${CONFIG_RPI_BOOT_SETTINGS[@]}"; do
        [[ "${line}" != *$'\n'* && "${line}" != *$'\r'* ]] || {
            printf 'Raspberry Pi boot settings must contain one line per array item\n' >&2
            return 1
        }
        ((${#line} <= 98)) || {
            printf 'Raspberry Pi boot setting exceeds the 98-character limit\n' >&2
            return 1
        }
        [[ ! "${line}" =~ ^[[:space:]]*include[[:space:]]+linux-scripts[.]txt([[:space:]]|$) ]] || {
            printf 'Raspberry Pi boot settings cannot include their own fragment\n' >&2
            return 1
        }
    done
}

configureRpiBoot() {
    local boot_config="${1:-}"
    local boot_dir
    local current_boot_config
    local fragment

    validateRpiBootConfiguration
    isRaspberryPi || {
        printf 'Raspberry Pi boot configuration requested on another platform\n' >&2
        return 1
    }

    if [[ -z "${boot_config}" ]]; then
        if [[ -f /boot/firmware/config.txt ]]; then
            boot_config="/boot/firmware/config.txt"
        else
            boot_config="/boot/config.txt"
        fi
    fi
    [[ "${boot_config}" == /* && -f "${boot_config}" &&
        -r "${boot_config}" && -w "${boot_config}" ]] || {
        printf 'Raspberry Pi boot configuration is not writable: %s\n' \
            "${boot_config}" >&2
        return 1
    }

    boot_dir="${boot_config%/*}"
    fragment="${boot_dir}/${RPI_MANAGED_BOOT_FRAGMENT}"

    {
        printf '%s\n' \
            '# Managed by linux-scripts init.' \
            '# Host-specific settings begin from a neutral filter.'
        printf '[all]\n'
        printf '%s\n' "${CONFIG_RPI_BOOT_SETTINGS[@]}"
        # Avoid leaking the final user-selected filter into config.txt after
        # the textual include returns.
        printf '[all]\n'
    } | installConfigFile "${fragment}"

    if ! grep -Eq \
        '^[[:space:]]*include[[:space:]]+linux-scripts[.]txt([[:space:]]*(#.*)?)?$' \
        "${boot_config}"; then
        current_boot_config="$(<"${boot_config}")"
        printf '%s\n\n%s\ninclude %s\n' \
            "${current_boot_config}" \
            '# Managed host-specific settings.' \
            "${RPI_MANAGED_BOOT_FRAGMENT}" |
            installConfigFile "${boot_config}"
    else
        chmod 0644 -- "${boot_config}"
    fi

    printf 'Raspberry Pi boot settings installed: %s\n' "${fragment}"
}
