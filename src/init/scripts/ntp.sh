#!/usr/bin/env bash

# Provisioning module: system time synchronization.
#
# Configures either systemd-timesyncd or Chrony. The selected package is
# installed by system_update.sh before this module changes daemon settings.
# Chrony is always client-only and can require NTS authentication.
#
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

validateNtpServerList() {
    local variable_name="$1"
    local allow_empty="$2"
    local value server
    local -a servers=()

    [[ -v "${variable_name}" ]] || {
        printf 'Missing %s configuration\n' "${variable_name}" >&2
        return 1
    }
    value="${!variable_name}"
    [[ "${value}" != *[$'\r\n']* ]] || {
        printf '%s must be a single line\n' "${variable_name}" >&2
        return 1
    }

    read -r -a servers <<<"${value}"
    if ((${#servers[@]} == 0)); then
        [[ "${allow_empty}" == true ]] || {
            printf '%s must contain at least one server\n' \
                "${variable_name}" >&2
            return 1
        }
        return 0
    fi

    for server in "${servers[@]}"; do
        [[ "${server}" =~ ^[[:alnum:].:%_-]+$ &&
            "${server}" =~ [[:alnum:]] ]] || {
            printf 'Invalid server in %s: %s\n' \
                "${variable_name}" "${server}" >&2
            return 1
        }
    done
}

validateNtpConfiguration() {
    local minimum_sources server_count
    local -a servers=()

    case "${CONFIG_NTP_BACKEND:-}" in
        timesyncd | chrony) ;;
        *)
            printf 'CONFIG_NTP_BACKEND must be timesyncd or chrony\n' >&2
            return 1
            ;;
    esac

    validateNtpServerList CONFIG_NTP_SERVERS false || return
    if [[ "${CONFIG_NTP_BACKEND}" == timesyncd ]]; then
        validateNtpServerList CONFIG_NTP_FALLBACK_SERVERS true
        return
    fi

    case "${CONFIG_NTP_CHRONY_NTS:-}" in
        true | false) ;;
        *)
            printf 'CONFIG_NTP_CHRONY_NTS must be true or false\n' >&2
            return 1
            ;;
    esac

    minimum_sources="${CONFIG_NTP_CHRONY_MIN_SOURCES:-}"
    [[ "${minimum_sources}" =~ ^[1-9][0-9]*$ ]] || {
        printf 'CONFIG_NTP_CHRONY_MIN_SOURCES must be a positive integer\n' >&2
        return 1
    }
    read -r -a servers <<<"${CONFIG_NTP_SERVERS}"
    server_count="${#servers[@]}"
    ((minimum_sources <= server_count)) || {
        printf 'CONFIG_NTP_CHRONY_MIN_SOURCES exceeds the server count\n' >&2
        return 1
    }

    [[ "${CONFIG_NTP_CHRONY_MAX_UPDATE_SKEW:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        printf 'CONFIG_NTP_CHRONY_MAX_UPDATE_SKEW must be a non-negative number\n' >&2
        return 1
    }
    [[ "${CONFIG_NTP_CHRONY_LOG_CHANGE:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        printf 'CONFIG_NTP_CHRONY_LOG_CHANGE must be a non-negative number\n' >&2
        return 1
    }
}

renderTimesyncdConfig() {
    cat <<EOF
# Managed by linux-scripts. Local changes will be replaced.

[Time]
# Reset values accumulated from earlier drop-ins before setting this policy.
NTP=
NTP=${CONFIG_NTP_SERVERS}
FallbackNTP=
FallbackNTP=${CONFIG_NTP_FALLBACK_SERVERS}
EOF
}

renderChronyConfig() {
    local package_manager="$1"
    local drift_file leap_directive server nts_option=""
    local -a servers=()

    case "${package_manager}" in
        pacman)
            drift_file="/var/lib/chrony/drift"
            leap_directive="leapseclist /usr/share/zoneinfo/leap-seconds.list"
            ;;
        apt)
            drift_file="/var/lib/chrony/chrony.drift"
            leap_directive="leapsectz right/UTC"
            ;;
        *)
            printf 'Unsupported package manager for Chrony: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac

    [[ "${CONFIG_NTP_CHRONY_NTS}" == true ]] && nts_option=" nts"
    read -r -a servers <<<"${CONFIG_NTP_SERVERS}"

    printf '%s\n' \
        '# Managed by linux-scripts. Local changes will be replaced.' \
        '# Client-only time synchronization.' \
        ''
    for server in "${servers[@]}"; do
        printf 'server %s iburst%s\n' "${server}" "${nts_option}"
    done
    if [[ "${CONFIG_NTP_CHRONY_NTS}" == true ]]; then
        printf '\nauthselectmode require\n'
    fi
    cat <<EOF
minsources ${CONFIG_NTP_CHRONY_MIN_SOURCES}
maxupdateskew ${CONFIG_NTP_CHRONY_MAX_UPDATE_SKEW}

driftfile ${drift_file}
ntsdumpdir /var/lib/chrony

makestep 1.0 3
rtcsync
${leap_directive}

logchange ${CONFIG_NTP_CHRONY_LOG_CHANGE}

port 0
cmdport 0
EOF
}

disableNtpUnitIfPresent() {
    local unit="$1"

    if systemctl cat "${unit}" >/dev/null 2>&1; then
        systemctl disable "${unit}"
    fi
}

activateNtpUnit() {
    local selected_unit="$1"
    local conflicting_unit="$2"

    systemctl enable "${selected_unit}" || return
    systemctl restart "${selected_unit}" || return
    systemctl is-active --quiet "${selected_unit}" || return
    disableNtpUnitIfPresent "${conflicting_unit}"
}

configureTimesyncd() {
    local root_prefix="$1"
    local config_file="${root_prefix}/etc/systemd/timesyncd.conf.d/90-linux-scripts-ntp.conf"
    local candidate

    systemctl cat systemd-timesyncd.service >/dev/null 2>&1 || {
        printf 'systemd-timesyncd is not installed\n' >&2
        return 1
    }

    candidate="$(mktemp)" || return
    if ! renderTimesyncdConfig >"${candidate}" ||
        ! installConfigFile "${config_file}" <"${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi
    rm -f -- "${candidate}"

    activateNtpUnit systemd-timesyncd.service chronyd.service
}

configureChrony() {
    local root_prefix="$1"
    local package_manager="$2"
    local config_file candidate

    case "${package_manager}" in
        pacman) config_file="${root_prefix}/etc/chrony.conf" ;;
        apt) config_file="${root_prefix}/etc/chrony/chrony.conf" ;;
        *)
            printf 'Unsupported package manager for Chrony: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac

    checkCommand chronyd || return
    systemctl cat chronyd.service >/dev/null 2>&1 || {
        printf 'chronyd.service is not installed\n' >&2
        return 1
    }

    candidate="$(mktemp)" || return
    if ! renderChronyConfig "${package_manager}" >"${candidate}" ||
        ! chronyd -p -f "${candidate}" >/dev/null; then
        rm -f -- "${candidate}"
        printf 'Generated Chrony configuration is invalid\n' >&2
        return 1
    fi
    if ! installConfigFile "${config_file}" <"${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi
    rm -f -- "${candidate}"

    activateNtpUnit chronyd.service systemd-timesyncd.service
}

customNtp() {
    local root_prefix="${1:-}"
    local package_manager

    validateNtpConfiguration || return
    checkCommand systemctl || return
    [[ -z "${root_prefix}" || "${root_prefix}" == /* ]] || {
        printf 'customNtp: test root must be absolute\n' >&2
        return 2
    }

    package_manager="$(selected_package_manager)" || return
    printf '\nConfiguring time synchronization with %s\n' \
        "${CONFIG_NTP_BACKEND}"

    case "${CONFIG_NTP_BACKEND}" in
        timesyncd) configureTimesyncd "${root_prefix}" ;;
        chrony) configureChrony "${root_prefix}" "${package_manager}" ;;
        *) return 1 ;;
    esac
}
