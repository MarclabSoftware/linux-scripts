#!/usr/bin/env bash

# Provisioning module: RFKill.
#
# Soft-blocks configured radio types or numeric RFKill device IDs. On systemd
# hosts, systemd-rfkill normally saves the resulting state and restores it at
# boot. Configuration and shared helpers are injected by init.sh.

parseRfkillTargets() {
    local target_list="$1"
    local output_name="$2"
    local -n output_ref="${output_name}"
    local -a raw_targets=()
    local target

    output_ref=()
    [[ -n "${target_list}" ]] || {
        printf 'CONFIG_RFKILL_TARGETS must not be empty\n' >&2
        return 1
    }

    IFS=, read -r -a raw_targets <<<"${target_list}"
    for target in "${raw_targets[@]}"; do
        target="${target#"${target%%[![:space:]]*}"}"
        target="${target%"${target##*[![:space:]]}"}"

        case "${target}" in
            all | wlan | wifi | bluetooth | uwb | ultrawideband | \
                wimax | wwan | gps | fm | nfc)
                ;;
            *)
                [[ "${target}" =~ ^[0-9]+$ ]] || {
                    printf 'Invalid RFKill target: %s\n' \
                        "${target:-<empty>}" >&2
                    return 1
                }
                ;;
        esac
        output_ref+=("${target}")
    done
}

validateRfkillTargets() {
    local -a targets=()

    parseRfkillTargets "${1:-}" targets
}

blockRf() {
    local -a targets=()

    checkCommand rfkill || return 1
    parseRfkillTargets "${CONFIG_RFKILL_TARGETS:-}" targets

    printf '\nRFKill targets to block: %s\n' "${targets[*]}"
    rfkill block "${targets[@]}"
}
