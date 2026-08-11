#!/usr/bin/env bash

# Validate network sysctl generation without changing the running host.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=../src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=../src/init/scripts/network.sh
. "${REPO_ROOT}/src/init/scripts/network.sh"

CONFIG_NETWORK_IPV4_FORWARDING=true
CONFIG_NETWORK_IPV6_FORWARDING=false
CONFIG_NETWORK_RESERVED_PORTS="40000,41000-41010"
CONFIG_NETWORK_CONGESTION_CONTROL="bbr"
CONFIG_NETWORK_DEFAULT_QDISC="fq"
validateNetworkConfiguration

expect_invalid_network_configuration() {
    local description="$1"
    local validation_status

    set +e
    validateNetworkConfiguration >/dev/null 2>&1
    validation_status=$?
    set -e
    if ((validation_status == 0)); then
        printf 'invalid network configuration was accepted: %s\n' \
            "${description}" >&2
        exit 1
    fi
}

for invalid_ports in "0" "65536" "100-99" "80,,443" "ssh"; do
    CONFIG_NETWORK_RESERVED_PORTS="${invalid_ports}"
    expect_invalid_network_configuration "reserved ports ${invalid_ports}"
done
CONFIG_NETWORK_RESERVED_PORTS="40000,41000-41010"

CONFIG_NETWORK_IPV6_FORWARDING=maybe
expect_invalid_network_configuration 'IPv6 forwarding boolean'
CONFIG_NETWORK_IPV6_FORWARDING=false

CONFIG_NETWORK_CONGESTION_CONTROL='bbr;reboot'
expect_invalid_network_configuration 'congestion-control algorithm'
CONFIG_NETWORK_CONGESTION_CONTROL=bbr

command_log="${TEST_TMP}/commands.log"
readonly command_log

checkCommand() {
    return 0
}

sysctl() {
    printf 'sysctl %s\n' "$*" >>"${command_log}"
}

for legacy_name in \
    21-network_optimizations.conf \
    21-network_routing.conf \
    21-network_ipv6_disable.conf; do
    legacy_file="${TEST_TMP}/etc/sysctl.d/${legacy_name}"
    mkdir -p -- "${legacy_file%/*}"
    printf 'legacy\n' >"${legacy_file}"
done

configureNetwork "${TEST_TMP}" >/dev/null

config_file="${TEST_TMP}/etc/sysctl.d/90-linux-scripts-network.conf"
grep -qxF '# Managed by linux-scripts init.' "${config_file}"
grep -qxF 'net.core.default_qdisc = fq' "${config_file}"
grep -qxF 'net.ipv4.tcp_congestion_control = bbr' "${config_file}"
grep -qxF 'net.ipv4.ip_local_reserved_ports = 40000,41000-41010' \
    "${config_file}"
grep -qxF 'net.ipv4.ip_forward = 1' "${config_file}"
grep -qxF 'net.ipv6.conf.all.forwarding = 0' "${config_file}"
grep -qxF 'net.ipv4.conf.*.rp_filter = 2' "${config_file}"
grep -qxF 'net.ipv6.conf.*.accept_source_route = -1' "${config_file}"
if grep -Eq 'tcp_(fastopen|keepalive|rfc1337|slow_start_after_idle)|ip_local_port_range' \
    "${config_file}"; then
    printf 'network configuration contains an intentionally omitted tuning\n' >&2
    exit 1
fi
config_mode="$(stat -c '%a' -- "${config_file}")"
[[ "${config_mode}" == 644 ]]
grep -qxF "sysctl --load=${config_file}" "${command_log}"

for legacy_name in \
    21-network_optimizations.conf \
    21-network_routing.conf \
    21-network_ipv6_disable.conf; do
    [[ ! -e "${TEST_TMP}/etc/sysctl.d/${legacy_name}" ]]
done

# An empty reservation omits the key and IPv6 forwarding remains per-host.
CONFIG_NETWORK_IPV6_FORWARDING=true
CONFIG_NETWORK_RESERVED_PORTS=""
configureNetwork "${TEST_TMP}" >/dev/null
if grep -q '^net.ipv4.ip_local_reserved_ports' "${config_file}"; then
    printf 'empty reserved-port policy still produced a sysctl setting\n' >&2
    exit 1
fi
grep -qxF 'net.ipv6.conf.all.forwarding = 1' "${config_file}"

printf 'init network tests passed\n'
