#!/usr/bin/env bash

# Provisioning Module: systemd-resolved
# Version: 3.0.0
# Updated: 2026-08-09
# Installs a validated global resolver policy and selects the matching
# systemd-managed resolv.conf mode. Per-link DNS routing remains the network
# manager's responsibility.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154,SC2310

validateSystemdResolvedConfiguration() {
    local variable value

    for variable in CONFIG_RESOLVED_DNS CONFIG_RESOLVED_FALLBACK_DNS; do
        [[ -v "${variable}" ]] || {
            printf 'Missing %s configuration\n' "${variable}" >&2
            return 1
        }
        value="${!variable}"
        [[ "${value}" != *[$'\r\n']* ]] || {
            printf '%s must be a single line\n' "${variable}" >&2
            return 1
        }
    done

    case "${CONFIG_RESOLVED_DNSSEC:-}" in
        yes | no | allow-downgrade) ;;
        *)
            printf 'CONFIG_RESOLVED_DNSSEC must be yes, no or allow-downgrade\n' >&2
            return 1
            ;;
    esac
    case "${CONFIG_RESOLVED_DNS_OVER_TLS:-}" in
        yes | no | opportunistic) ;;
        *)
            printf 'CONFIG_RESOLVED_DNS_OVER_TLS must be yes, no or opportunistic\n' >&2
            return 1
            ;;
    esac
    for variable in CONFIG_RESOLVED_LLMNR CONFIG_RESOLVED_MULTICAST_DNS; do
        case "${!variable:-}" in
            yes | no | resolve) ;;
            *)
                printf '%s must be yes, no or resolve\n' "${variable}" >&2
                return 1
                ;;
        esac
    done
    case "${CONFIG_RESOLVED_STUB_LISTENER:-}" in
        yes | no | udp | tcp) ;;
        *)
            printf 'CONFIG_RESOLVED_STUB_LISTENER must be yes, no, udp or tcp\n' >&2
            return 1
            ;;
    esac
    case "${CONFIG_RESOLVED_RESOLV_CONF_MODE:-}" in
        uplink) ;;
        stub)
            [[ "${CONFIG_RESOLVED_STUB_LISTENER}" != no ]] || {
                printf 'stub resolv.conf mode requires an enabled DNS stub listener\n' >&2
                return 1
            }
            ;;
        *)
            printf 'CONFIG_RESOLVED_RESOLV_CONF_MODE must be uplink or stub\n' >&2
            return 1
            ;;
    esac
}

renderSystemdResolvedConfig() {
    cat <<EOF
# Managed by linux-scripts. Local changes will be replaced.
# Per-link DNS servers and routing domains belong in the network configuration.

[Resolve]
DNS=${CONFIG_RESOLVED_DNS}
FallbackDNS=${CONFIG_RESOLVED_FALLBACK_DNS}
DNSSEC=${CONFIG_RESOLVED_DNSSEC}
DNSOverTLS=${CONFIG_RESOLVED_DNS_OVER_TLS}
LLMNR=${CONFIG_RESOLVED_LLMNR}
MulticastDNS=${CONFIG_RESOLVED_MULTICAST_DNS}
DNSStubListener=${CONFIG_RESOLVED_STUB_LISTENER}
EOF
}

resolvedManagerProperty() {
    local property="$1"
    local output

    output="$(busctl get-property \
        org.freedesktop.resolve1 \
        /org/freedesktop/resolve1 \
        org.freedesktop.resolve1.Manager \
        "${property}")" || return
    [[ "${output}" =~ ^s\ \"([^\"]*)\"$ ]] || {
        printf 'Unexpected systemd-resolved D-Bus value for %s: %s\n' \
            "${property}" "${output}" >&2
        return 1
    }
    printf '%s\n' "${BASH_REMATCH[1]}"
}

assertResolvedManagerProperty() {
    local property="$1"
    local expected="$2"
    local actual

    actual="$(resolvedManagerProperty "${property}")" || return
    [[ "${actual}" == "${expected}" ]] || {
        printf 'Effective systemd-resolved property %s is %q, expected %q\n' \
            "${property}" "${actual}" "${expected}" >&2
        return 1
    }
}

validateEffectiveSystemdResolved() {
    local resolv_conf="$1"
    local desired_resolv_conf="$2"
    local canonical_target canonical_expected

    systemctl is-active --quiet systemd-resolved.service || return
    resolvectl status >/dev/null || return
    [[ -L "${resolv_conf}" ]] || {
        printf '%s is not a symbolic link\n' "${resolv_conf}" >&2
        return 1
    }
    canonical_target="$(readlink -f -- "${resolv_conf}")" || return
    canonical_expected="$(readlink -f -- "${desired_resolv_conf}")" || return
    [[ "${canonical_target}" == "${canonical_expected}" ]] || {
        printf '%s points to %s, expected %s\n' \
            "${resolv_conf}" "${canonical_target}" \
            "${canonical_expected}" >&2
        return 1
    }

    assertResolvedManagerProperty LLMNR "${CONFIG_RESOLVED_LLMNR}" || return
    assertResolvedManagerProperty MulticastDNS \
        "${CONFIG_RESOLVED_MULTICAST_DNS}" || return
    assertResolvedManagerProperty DNSSEC "${CONFIG_RESOLVED_DNSSEC}" || return
    assertResolvedManagerProperty DNSOverTLS \
        "${CONFIG_RESOLVED_DNS_OVER_TLS}" || return
    assertResolvedManagerProperty DNSStubListener \
        "${CONFIG_RESOLVED_STUB_LISTENER}" || return
    assertResolvedManagerProperty ResolvConfMode \
        "${CONFIG_RESOLVED_RESOLV_CONF_MODE}" || return
}

restoreSystemdResolvedFiles() {
    local target_config="$1"
    local config_backup="$2"
    local config_existed="$3"
    local resolv_conf="$4"
    local resolv_conf_backup="$5"
    local resolv_conf_existed="$6"
    local failed=false

    if [[ "${config_existed}" == true ]]; then
        mv -f -- "${config_backup}" "${target_config}" || failed=true
    else
        rm -f -- "${target_config}" || failed=true
    fi
    rm -f -- "${resolv_conf}" || failed=true
    if [[ "${resolv_conf_existed}" == true ]]; then
        mv -- "${resolv_conf_backup}" "${resolv_conf}" || failed=true
    fi
    [[ "${failed}" == false ]]
}

cleanupSystemdResolvedTransaction() {
    local transaction_dir="$1"
    local resolv_conf_dir="$2"

    [[ "${transaction_dir}" == "${resolv_conf_dir}"/.linux-scripts-resolved.* ]] || {
        printf 'Refusing unsafe resolver transaction cleanup: %s\n' \
            "${transaction_dir}" >&2
        return 1
    }
    rm -rf -- "${transaction_dir}"
}

configureSystemdResolved() {
    local drop_in_dir="${1:-/etc/systemd/resolved.conf.d}"
    local resolv_conf="${2:-/etc/resolv.conf}"
    local runtime_dir="${3:-/run/systemd/resolve}"
    local target_config="${drop_in_dir}/90-linux-scripts-resolved.conf"
    local resolv_conf_dir="${resolv_conf%/*}"
    local desired_resolv_conf
    local transaction_dir candidate config_backup resolv_conf_backup new_link
    local config_existed=false
    local resolv_conf_existed=false

    validateSystemdResolvedConfiguration || return
    checkCommand busctl || return
    checkCommand resolvectl || return
    checkCommand systemctl || return
    [[ "${drop_in_dir}" == /* && "${resolv_conf}" == /* &&
        "${runtime_dir}" == /* ]] || {
        printf 'systemd-resolved paths must be absolute\n' >&2
        return 1
    }
    [[ ! -L "${drop_in_dir}" && ! -L "${target_config}" ]] || {
        printf 'Symbolic-link resolver drop-in path rejected: %s\n' \
            "${target_config}" >&2
        return 1
    }
    [[ ! -d "${resolv_conf}" ]] || {
        printf 'resolv.conf path is a directory: %s\n' "${resolv_conf}" >&2
        return 1
    }

    case "${CONFIG_RESOLVED_RESOLV_CONF_MODE}" in
        uplink) desired_resolv_conf="${runtime_dir}/resolv.conf" ;;
        stub) desired_resolv_conf="${runtime_dir}/stub-resolv.conf" ;;
        *)
            printf 'Unsupported resolv.conf mode after validation\n' >&2
            return 1
            ;;
    esac

    systemctl enable --now systemd-resolved.service || return
    [[ -e "${desired_resolv_conf}" ]] || {
        printf 'systemd-resolved managed file is missing: %s\n' \
            "${desired_resolv_conf}" >&2
        return 1
    }

    [[ -n "${resolv_conf_dir}" ]] || resolv_conf_dir="/"
    transaction_dir="$(mktemp -d -- \
        "${resolv_conf_dir}/.linux-scripts-resolved.XXXXXX")" || return
    candidate="${transaction_dir}/resolved.conf"
    config_backup="${transaction_dir}/previous-resolved.conf"
    resolv_conf_backup="${transaction_dir}/previous-resolv.conf"
    new_link="${transaction_dir}/new-resolv.conf"

    if ! renderSystemdResolvedConfig >"${candidate}"; then
        cleanupSystemdResolvedTransaction "${transaction_dir}" \
            "${resolv_conf_dir}" || true
        return 1
    fi
    if [[ -e "${target_config}" ]]; then
        config_existed=true
        if ! cp -a -- "${target_config}" "${config_backup}"; then
            cleanupSystemdResolvedTransaction "${transaction_dir}" \
                "${resolv_conf_dir}" || true
            return 1
        fi
    fi
    if [[ -e "${resolv_conf}" || -L "${resolv_conf}" ]]; then
        resolv_conf_existed=true
        if ! cp -a -- "${resolv_conf}" "${resolv_conf_backup}"; then
            cleanupSystemdResolvedTransaction "${transaction_dir}" \
                "${resolv_conf_dir}" || true
            return 1
        fi
    fi

    if ! installConfigFile "${target_config}" <"${candidate}" ||
        ! chown root:root "${target_config}" ||
        ! ln -s -- "${desired_resolv_conf}" "${new_link}" ||
        ! mv -Tf -- "${new_link}" "${resolv_conf}" ||
        ! systemctl reload-or-restart systemd-resolved.service ||
        ! validateEffectiveSystemdResolved "${resolv_conf}" \
            "${desired_resolv_conf}"; then
        if restoreSystemdResolvedFiles \
            "${target_config}" "${config_backup}" "${config_existed}" \
            "${resolv_conf}" "${resolv_conf_backup}" \
            "${resolv_conf_existed}" &&
            systemctl reload-or-restart systemd-resolved.service; then
            cleanupSystemdResolvedTransaction "${transaction_dir}" \
                "${resolv_conf_dir}" || true
            printf 'systemd-resolved validation failed; previous files restored\n' >&2
        else
            printf 'systemd-resolved rollback failed; recovery data retained at %s\n' \
                "${transaction_dir}" >&2
        fi
        return 1
    fi

    cleanupSystemdResolvedTransaction "${transaction_dir}" \
        "${resolv_conf_dir}" || return
    printf 'systemd-resolved configuration installed and validated\n'
}
