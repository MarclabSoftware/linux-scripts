#!/usr/bin/env bash

# Provisioning module: periodic filesystem trim and USB UNMAP quirks.
#
# The distribution-provided fstrim timer is sufficient for devices which
# advertise discard correctly. Some verified USB storage bridges need an
# explicit SCSI provisioning_mode override; only administrator-approved USB
# vendor/product IDs receive that narrowly scoped udev rule.
#
# Configuration and shared helpers are provided by init.sh.
# shellcheck disable=SC2154

readonly FSTRIM_USB_RULE_NAME="90-linux-scripts-fstrim-usb.rules"

validateFstrimConfiguration() {
    local declaration
    local device_id

    declaration="$(declare -p CONFIG_FSTRIM_USB_UNMAP_IDS 2>/dev/null)" || {
        printf 'CONFIG_FSTRIM_USB_UNMAP_IDS must be an indexed Bash array\n' >&2
        return 1
    }
    [[ "${declaration}" == "declare -a "* ]] || {
        printf 'CONFIG_FSTRIM_USB_UNMAP_IDS must be an indexed Bash array\n' >&2
        return 1
    }

    for device_id in "${CONFIG_FSTRIM_USB_UNMAP_IDS[@]}"; do
        [[ "${device_id}" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] || {
            printf 'Invalid USB UNMAP ID: %s (expected VVVV:PPPP)\n' \
                "${device_id:-<empty>}" >&2
            return 1
        }
    done
}

configureFstrim() {
    local root="${1:-}"
    local rules_file
    local legacy_rules_file
    local device_id
    local vendor_id
    local product_id
    local rules_changed=false
    local -a rules=(
        '# Managed by linux-scripts init.'
        '# Force UNMAP only for USB storage bridges verified by the administrator.'
    )

    [[ -z "${root}" || "${root}" == /* ]] || {
        printf 'configureFstrim: test root must be absolute\n' >&2
        return 2
    }
    root="${root%/}"
    rules_file="${root}/etc/udev/rules.d/${FSTRIM_USB_RULE_NAME}"
    legacy_rules_file="${root}/etc/udev/rules.d/21-ssd_trim.rules"

    validateFstrimConfiguration

    if ((${#CONFIG_FSTRIM_USB_UNMAP_IDS[@]} > 0)); then
        for device_id in "${CONFIG_FSTRIM_USB_UNMAP_IDS[@]}"; do
            vendor_id="${device_id%%:*}"
            product_id="${device_id##*:}"
            rules+=(
                "ACTION==\"add|change\", SUBSYSTEM==\"scsi_disk\", ATTRS{idVendor}==\"${vendor_id,,}\", ATTRS{idProduct}==\"${product_id,,}\", TEST==\"provisioning_mode\", ATTR{provisioning_mode}=\"unmap\""
            )
        done
        printf '%s\n' "${rules[@]}" | installConfigFile "${rules_file}"
        rules_changed=true
    elif [[ -e "${rules_file}" || -L "${rules_file}" ]]; then
        rm -f -- "${rules_file}"
        rules_changed=true
    fi

    # Remove only the rule produced by the superseded module.
    if [[ -e "${legacy_rules_file}" || -L "${legacy_rules_file}" ]]; then
        rm -f -- "${legacy_rules_file}"
        rules_changed=true
    fi

    if [[ "${rules_changed}" == true ]]; then
        checkCommand udevadm
        udevadm control --reload-rules
    fi
    enableService "fstrim.timer" true

    if ((${#CONFIG_FSTRIM_USB_UNMAP_IDS[@]} > 0)); then
        printf 'USB UNMAP quirks installed; reboot or reconnect applies them\n'
    fi
}
