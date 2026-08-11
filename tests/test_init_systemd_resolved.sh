#!/usr/bin/env bash

# Exercise systemd-resolved provisioning without changing the host resolver.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/systemd_resolved.sh
. "${REPO_ROOT}/src/init/scripts/systemd_resolved.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

CONFIG_RESOLVED_DNS=""
CONFIG_RESOLVED_FALLBACK_DNS=""
CONFIG_RESOLVED_DNSSEC="no"
CONFIG_RESOLVED_DNS_OVER_TLS="no"
CONFIG_RESOLVED_LLMNR="no"
CONFIG_RESOLVED_MULTICAST_DNS="yes"
CONFIG_RESOLVED_STUB_LISTENER="no"
CONFIG_RESOLVED_RESOLV_CONF_MODE="uplink"
validateSystemdResolvedConfiguration

CONFIG_RESOLVED_RESOLV_CONF_MODE="stub"
expect_failure validateSystemdResolvedConfiguration
CONFIG_RESOLVED_STUB_LISTENER="yes"
validateSystemdResolvedConfiguration
CONFIG_RESOLVED_STUB_LISTENER="no"
CONFIG_RESOLVED_RESOLV_CONF_MODE="uplink"
CONFIG_RESOLVED_DNS=$'192.0.2.53\nDNSSEC=yes'
expect_failure validateSystemdResolvedConfiguration
CONFIG_RESOLVED_DNS=""

SYSTEMCTL_LOG="${TEST_TMP}/systemctl.log"
RESOLVED_TEST_FAIL_EFFECTIVE=false

systemctl() {
    case "$1" in
        enable)
            [[ "$2" == --now && "$3" == systemd-resolved.service ]]
            ;;
        is-active)
            [[ "$2" == --quiet && "$3" == systemd-resolved.service ]]
            ;;
        reload-or-restart)
            [[ "$2" == systemd-resolved.service ]]
            printf '%s\n' "$2" >>"${SYSTEMCTL_LOG}"
            ;;
        *)
            return 2
            ;;
    esac
}

resolvectl() {
    [[ "$1" == status ]]
}

busctl() {
    local property="${5:-}"
    local value

    [[ "$1" == get-property ]] || return 2
    case "${property}" in
        LLMNR) value="${CONFIG_RESOLVED_LLMNR}" ;;
        MulticastDNS) value="${CONFIG_RESOLVED_MULTICAST_DNS}" ;;
        DNSSEC)
            if [[ "${RESOLVED_TEST_FAIL_EFFECTIVE}" == true ]]; then
                value=yes
            else
                value="${CONFIG_RESOLVED_DNSSEC}"
            fi
            ;;
        DNSOverTLS) value="${CONFIG_RESOLVED_DNS_OVER_TLS}" ;;
        DNSStubListener) value="${CONFIG_RESOLVED_STUB_LISTENER}" ;;
        ResolvConfMode) value="${CONFIG_RESOLVED_RESOLV_CONF_MODE}" ;;
        *) return 2 ;;
    esac
    printf 's "%s"\n' "${value}"
}

# configureSystemdResolved normally runs as root through init.sh; ownership is
# not material in this unprivileged temporary-directory test.
chown() {
    return 0
}

drop_in_dir="${TEST_TMP}/etc/systemd/resolved.conf.d"
resolv_conf="${TEST_TMP}/etc/resolv.conf"
runtime_dir="${TEST_TMP}/run/systemd/resolve"
target_config="${drop_in_dir}/90-linux-scripts-resolved.conf"
mkdir -p -- "${resolv_conf%/*}" "${runtime_dir}"
printf 'original resolver file\n' >"${resolv_conf}"
printf 'nameserver 192.0.2.53\n' >"${runtime_dir}/resolv.conf"
printf 'nameserver 127.0.0.53\n' >"${runtime_dir}/stub-resolv.conf"

configureSystemdResolved "${drop_in_dir}" "${resolv_conf}" \
    "${runtime_dir}" >/dev/null
grep -Fx 'DNS=' "${target_config}" >/dev/null
grep -Fx 'FallbackDNS=' "${target_config}" >/dev/null
grep -Fx 'MulticastDNS=yes' "${target_config}" >/dev/null
[[ -L "${resolv_conf}" ]]
current_link="$(readlink -- "${resolv_conf}")"
[[ "${current_link}" == "${runtime_dir}/resolv.conf" ]]
target_mode="$(stat -c '%a' "${target_config}")"
reload_count="$(grep -cxF systemd-resolved.service "${SYSTEMCTL_LOG}")"
[[ "${target_mode}" == 644 ]]
[[ "${reload_count}" == 1 ]]
[[ ! -e "${resolv_conf}.bak" ]]

# Reapplying the policy is deterministic and reloads the daemon configuration.
configureSystemdResolved "${drop_in_dir}" "${resolv_conf}" \
    "${runtime_dir}" >/dev/null
reload_count="$(grep -cxF systemd-resolved.service "${SYSTEMCTL_LOG}")"
[[ "${reload_count}" == 2 ]]

# An effective-property mismatch restores both the drop-in and resolv.conf.
previous_config="$(<"${target_config}")"
previous_link="$(readlink -- "${resolv_conf}")"
CONFIG_RESOLVED_MULTICAST_DNS="no"
RESOLVED_TEST_FAIL_EFFECTIVE=true
expect_failure configureSystemdResolved "${drop_in_dir}" "${resolv_conf}" \
    "${runtime_dir}"
[[ "$(<"${target_config}")" == "${previous_config}" ]]
current_link="$(readlink -- "${resolv_conf}")"
[[ "${current_link}" == "${previous_link}" ]]
reload_count="$(grep -cxF systemd-resolved.service "${SYSTEMCTL_LOG}")"
[[ "${reload_count}" == 4 ]]

if compgen -G "${resolv_conf%/*}/.linux-scripts-resolved.*" >/dev/null; then
    printf 'resolver transaction directory was not removed\n' >&2
    exit 1
fi

printf 'init systemd-resolved tests passed\n'
