#!/usr/bin/env bash

# Provisioning module: Raspberry Pi bootloader EEPROM.
#
# Selects an official release track and stages any available update for the
# mandatory phase-one reboot. The update deliberately omits `-d`, preserving
# the board's existing EEPROM configuration such as BOOT_ORDER.
#
# Configuration and shared helpers are provided by init.sh.
# shellcheck disable=SC2154

validateRpiEepromConfiguration() {
    case "${CONFIG_RPI_EEPROM_RELEASE:-}" in
        default | latest) ;;
        *)
            printf 'CONFIG_RPI_EEPROM_RELEASE must be default or latest\n' >&2
            return 1
            ;;
    esac
}

configureRpiEeprom() {
    local defaults_file="${1:-/etc/default/rpi-eeprom-update}"
    local release="${CONFIG_RPI_EEPROM_RELEASE:-}"
    local assignment_written=false
    local line
    local -a updated_defaults=()

    [[ "${defaults_file}" == /* ]] || {
        printf 'configureRpiEeprom: defaults path must be absolute\n' >&2
        return 2
    }

    validateRpiEepromConfiguration
    isRaspberryPi || {
        printf 'Raspberry Pi EEPROM configuration requested on another platform\n' >&2
        return 1
    }
    checkCommand rpi-eeprom-update
    [[ -f "${defaults_file}" && -r "${defaults_file}" ]] || {
        printf 'EEPROM defaults file is not readable: %s\n' \
            "${defaults_file}" >&2
        return 1
    }

    # Replace every active assignment with one canonical value, or append it
    # when older package defaults do not contain the setting.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*FIRMWARE_RELEASE_STATUS[[:space:]]*= ]]; then
            if [[ "${assignment_written}" == false ]]; then
                updated_defaults+=("FIRMWARE_RELEASE_STATUS=\"${release}\"")
                assignment_written=true
            fi
        else
            updated_defaults+=("${line}")
        fi
    done <"${defaults_file}"
    if [[ "${assignment_written}" == false ]]; then
        updated_defaults+=("FIRMWARE_RELEASE_STATUS=\"${release}\"")
    fi
    printf '%s\n' "${updated_defaults[@]}" |
        installConfigFile "${defaults_file}"

    rpi-eeprom-update -a
    printf 'Raspberry Pi EEPROM release set to %s; update check completed\n' \
        "${release}"
}
