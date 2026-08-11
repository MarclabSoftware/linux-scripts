#!/usr/bin/env bash

# Provisioning module: host network policy.
#
# Installs one sysctl.d file containing the conservative settings shared by
# the managed hosts. Only forwarding, reserved ports and the congestion-control
# algorithm vary by host; the kernel retains control of unrelated networking
# parameters.
#
# Configuration and shared helpers are provided by init.sh.
# shellcheck disable=SC2154

validateNetworkConfiguration() {
    local setting
    local value
    local port_item
    local port_start
    local port_end
    local -a port_items=()

    for setting in \
        CONFIG_NETWORK_IPV4_FORWARDING \
        CONFIG_NETWORK_IPV6_FORWARDING; do
        case "${!setting:-}" in
            true | false) ;;
            *)
                printf '%s must be true or false\n' "${setting}" >&2
                return 1
                ;;
        esac
    done

    for setting in \
        CONFIG_NETWORK_CONGESTION_CONTROL \
        CONFIG_NETWORK_DEFAULT_QDISC; do
        value="${!setting:-}"
        [[ "${value}" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || {
            printf '%s must be a kernel algorithm name\n' "${setting}" >&2
            return 1
        }
    done

    value="${CONFIG_NETWORK_RESERVED_PORTS:-}"
    [[ -z "${value}" ]] && return 0
    [[ "${value}" =~ ^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$ ]] || {
        printf 'CONFIG_NETWORK_RESERVED_PORTS must contain comma-separated ports or ranges\n' >&2
        return 1
    }

    IFS=, read -r -a port_items <<<"${value}"
    for port_item in "${port_items[@]}"; do
        [[ "${port_item}" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]]
        port_start=$((10#${BASH_REMATCH[1]}))
        port_end="${BASH_REMATCH[3]:-${port_start}}"
        port_end=$((10#${port_end}))
        if ((port_start < 1 || port_end > 65535 || port_start > port_end)); then
            printf 'Invalid reserved port or range: %s\n' "${port_item}" >&2
            return 1
        fi
    done
}

ensureCongestionControlAvailable() {
    local requested="$1"
    local available

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control)" ||
        return 1
    [[ " ${available} " == *" ${requested} "* ]] && return 0

    if command -v modprobe >/dev/null 2>&1; then
        modprobe -- "tcp_${requested}" 2>/dev/null || true
        available="$(sysctl -n net.ipv4.tcp_available_congestion_control)" ||
            return 1
    fi
    [[ " ${available} " == *" ${requested} "* ]] || {
        printf 'TCP congestion control is unavailable: %s\n' \
            "${requested}" >&2
        return 1
    }
}

configureNetwork() {
    local root="${1:-}"
    local sysctl_conf
    local congestion_control="${CONFIG_NETWORK_CONGESTION_CONTROL:-}"
    local default_qdisc="${CONFIG_NETWORK_DEFAULT_QDISC:-}"
    local reserved_port_spec="${CONFIG_NETWORK_RESERVED_PORTS:-}"
    local ipv4_forwarding=0
    local ipv6_forwarding=0
    local -a configuration=(
        '# Managed by linux-scripts init.'
        '# Socket buffer ceilings are allocated on demand, not per socket.'
        'net.core.rmem_max = 33554432'
        'net.core.wmem_max = 33554432'
        'net.ipv4.tcp_rmem = 4096 131072 33554432'
        'net.ipv4.tcp_wmem = 4096 16384 33554432'
        '# Fair queueing and modern TCP congestion control.'
        "net.core.default_qdisc = ${default_qdisc}"
        "net.ipv4.tcp_congestion_control = ${congestion_control}"
        '# Enable packetization-layer MTU probing only after a black hole.'
        'net.ipv4.tcp_mtu_probing = 1'
    )
    local legacy_conf
    local -a legacy_confs=()

    [[ -z "${root}" || "${root}" == /* ]] || {
        printf 'configureNetwork: test root must be absolute\n' >&2
        return 2
    }
    root="${root%/}"
    sysctl_conf="${root}/etc/sysctl.d/90-linux-scripts-network.conf"
    legacy_confs=(
        "${root}/etc/sysctl.d/21-network_optimizations.conf"
        "${root}/etc/sysctl.d/21-network_routing.conf"
        "${root}/etc/sysctl.d/21-network_ipv6_disable.conf"
    )

    validateNetworkConfiguration
    checkCommand sysctl
    if [[ -z "${root}" ]]; then
        ensureCongestionControlAvailable "${congestion_control}"
    fi

    [[ "${CONFIG_NETWORK_IPV4_FORWARDING}" == true ]] && ipv4_forwarding=1
    [[ "${CONFIG_NETWORK_IPV6_FORWARDING}" == true ]] && ipv6_forwarding=1
    if [[ -n "${reserved_port_spec}" ]]; then
        configuration+=(
            '# Keep service ports out of automatic ephemeral allocation.'
            "net.ipv4.ip_local_reserved_ports = ${reserved_port_spec}"
        )
    fi
    configuration+=(
        '# Host-specific routing policy.'
        "net.ipv4.ip_forward = ${ipv4_forwarding}"
        "net.ipv6.conf.all.forwarding = ${ipv6_forwarding}"
        '# Safe defaults for Docker, VPNs and asymmetric routing.'
        'net.ipv4.conf.default.proxy_arp = 0'
        'net.ipv4.conf.*.proxy_arp = 0'
        'net.ipv4.conf.default.rp_filter = 2'
        'net.ipv4.conf.*.rp_filter = 2'
        'net.ipv4.conf.default.accept_redirects = 0'
        'net.ipv4.conf.*.accept_redirects = 0'
        'net.ipv4.conf.default.send_redirects = 0'
        'net.ipv4.conf.*.send_redirects = 0'
        'net.ipv4.conf.default.accept_source_route = 0'
        'net.ipv4.conf.*.accept_source_route = 0'
        'net.ipv6.conf.default.accept_redirects = 0'
        'net.ipv6.conf.*.accept_redirects = 0'
        'net.ipv6.conf.default.accept_source_route = -1'
        'net.ipv6.conf.*.accept_source_route = -1'
        '# Permit unprivileged ping sockets, including inside containers.'
        'net.ipv4.ping_group_range = 0 2147483647'
    )

    printf '%s\n' "${configuration[@]}" |
        installConfigFile "${sysctl_conf}"
    sysctl --load="${sysctl_conf}"

    # Remove only files created by the superseded network modules.
    for legacy_conf in "${legacy_confs[@]}"; do
        rm -f -- "${legacy_conf}"
    done

    printf 'Network configuration installed: %s\n' "${sysctl_conf}"
}
