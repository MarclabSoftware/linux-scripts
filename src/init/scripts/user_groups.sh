#!/usr/bin/env bash

# Provisioning module: supplementary user groups.
#
# The configured groups are requirements, not an exact membership policy:
# missing groups are added, while existing and distribution-managed memberships
# are never removed.
#
# Configuration and shared helpers are provided by init.sh.
# shellcheck disable=SC2154

parseUserGroupList() {
    if (($# != 2)) || [[ -z "$2" ]]; then
        printf 'parseUserGroupList: expected LIST OUTPUT_ARRAY\n' >&2
        return 2
    fi

    local group_list="$1"
    local output_name="$2"
    local -n output_ref="${output_name}"
    local group_name
    local known_group
    local duplicate
    local -a raw_groups=()

    output_ref=()
    [[ -n "${group_list}" ]] || {
        printf 'CONFIG_USER_GROUPS_TO_ADD must not be empty\n' >&2
        return 1
    }

    IFS=, read -r -a raw_groups <<<"${group_list}"
    for group_name in "${raw_groups[@]}"; do
        group_name="${group_name#"${group_name%%[![:space:]]*}"}"
        group_name="${group_name%"${group_name##*[![:space:]]}"}"
        [[ "${group_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] || {
            printf 'Invalid supplementary group name: %s\n' \
                "${group_name:-<empty>}" >&2
            return 1
        }

        duplicate=false
        for known_group in "${output_ref[@]}"; do
            if [[ "${known_group}" == "${group_name}" ]]; then
                duplicate=true
                break
            fi
        done
        [[ "${duplicate}" == true ]] || output_ref+=("${group_name}")
    done
}

validateUserGroupConfiguration() {
    local -a configured_groups=()

    parseUserGroupList "${CONFIG_USER_GROUPS_TO_ADD:-}" configured_groups
}

addUserToGroups() {
    local current_groups
    local group_name
    local missing_group_list
    local -a configured_groups=()
    local -a missing_groups=()

    isNormalUser "${CONFIG_USER}" || {
        printf 'CONFIG_USER must name an existing non-root user\n' >&2
        return 1
    }
    checkCommand getent
    checkCommand id
    checkCommand usermod
    parseUserGroupList "${CONFIG_USER_GROUPS_TO_ADD:-}" configured_groups

    current_groups="$(id -nG -- "${CONFIG_USER}")"
    for group_name in "${configured_groups[@]}"; do
        getent group "${group_name}" >/dev/null || {
            printf 'Supplementary group does not exist: %s\n' \
                "${group_name}" >&2
            return 1
        }
        if [[ " ${current_groups} " != *" ${group_name} "* ]]; then
            missing_groups+=("${group_name}")
        fi
    done

    if ((${#missing_groups[@]} == 0)); then
        printf '%s already belongs to every configured group\n' "${CONFIG_USER}"
        return 0
    fi

    missing_group_list="$(
        IFS=,
        printf '%s' "${missing_groups[*]}"
    )"
    usermod --append --groups "${missing_group_list}" -- "${CONFIG_USER}"
    printf 'Added %s to: %s; reboot activates the new memberships\n' \
        "${CONFIG_USER}" "${missing_group_list}"
}
