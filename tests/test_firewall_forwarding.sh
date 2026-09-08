#!/usr/bin/env bash

# No production rules are touched: kernel checks run in a fresh network namespace.
# Variables/functions provided by the sourced script are intentional.
# shellcheck disable=SC2154,SC2034,SC2329
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
FIREWALL_SCRIPT="${IP_BLOCKER_TEST_SCRIPT:-${REPO_ROOT}/src/scripts/ip_blocker.sh}"
readonly FIREWALL_SCRIPT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

export IP_BLOCKER_ENV_FILE="${TEST_TMP}/absent.env" IP_BLOCKER_NAT_INTERFACES=''
for name in nft ip unshare nsenter mount python3 jq timeout; do
    command -v "${name}" >/dev/null || {
        printf 'Firewall forwarding kernel tests require %s\n' "${name}"
        exit 77
    }
done
if [[ "${1:-}" != --isolated ]]; then
    if ! unshare -Urn true 2>/dev/null; then
        printf 'Firewall forwarding kernel tests require user/network namespaces\n'
        exit 77
    fi
    IP_BLOCKER_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)"
    export IP_BLOCKER_TEST_PARENT_NETNS
    unshare -Urnm bash "${BASH_SOURCE[0]}" --isolated
    exit
fi
test_netns="$(readlink /proc/self/ns/net)"
[[ -n "${IP_BLOCKER_TEST_PARENT_NETNS:-}" && "${test_netns}" != "${IP_BLOCKER_TEST_PARENT_NETNS}" ]] || exit 1
mount -t sysfs sysfs /sys
ip link set lo up
sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1

pids=()
cleanup_test() {
    for child in "${pids[@]}"; do kill "${child}" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf -- "${TEST_TMP}"
}
trap cleanup_test EXIT
new_namespace() {
    local child_netns
    unshare -n sleep 120 >/dev/null &
    new_pid=$!
    pids+=("${new_pid}")
    for _ in {1..100}; do
        child_netns="$(readlink "/proc/${new_pid}/ns/net")"
        [[ "${child_netns}" != "${test_netns}" ]] && return
        sleep 0.01
    done
    return 1
}
new_namespace
vpn_ns="${new_pid}"
new_namespace
wan_ns="${new_pid}"
new_namespace
docker_ns="${new_pid}"

for link_spec in "wg0:${vpn_ns}" "wan0:${wan_ns}" "dkr0:${docker_ns}"; do
    link="${link_spec%%:*}"
    peer_ns="${link_spec#*:}"
    ip link add "${link}" type veth peer name peer0
    ip link set peer0 netns "${peer_ns}"
    nsenter -t "${peer_ns}" -n ip link set peer0 name eth0
    nsenter -t "${peer_ns}" -n ip link set lo up
    nsenter -t "${peer_ns}" -n ip link set eth0 up
    ip link set "${link}" up
done
ip link add br-test type bridge
ip link set dkr0 master br-test
ip link set br-test up
for addresses in "wg0:10.200.1:fd00:d0c:1" "wan0:198.18.0:2001:db8:2" "br-test:172.19.0:fd00:d0c:3"; do
    link="${addresses%%:*}"
    addresses="${addresses#*:}"
    v4="${addresses%%:*}"
    v6="${addresses#*:}"
    case "${link}" in
        wg0) peer_ns="${vpn_ns}" ;;
        wan0) peer_ns="${wan_ns}" ;;
        br-test) peer_ns="${docker_ns}" ;;
        *) exit 1 ;;
    esac
    ip addr add "${v4}.1/24" dev "${link}"
    ip -6 addr add "${v6}::1/64" dev "${link}" nodad
    nsenter -t "${peer_ns}" -n ip addr add "${v4}.2/24" dev eth0
    nsenter -t "${peer_ns}" -n ip -6 addr add "${v6}::2/64" dev eth0 nodad
    nsenter -t "${peer_ns}" -n ip route add default via "${v4}.1"
    nsenter -t "${peer_ns}" -n ip -6 route add default via "${v6}::1"
done

export IP_BLOCKER_ENV_FILE="${TEST_TMP}/absent.env" IP_BLOCKER_NAT_INTERFACES=''
export IP_BLOCKER_FLOWTABLE_INTERFACES='wg0 wan0 br-test'
export IP_BLOCKER_FLOWTABLE_TRUSTED_INTERFACES='wg0 br-test'
export IP_BLOCKER_COUNTRIES=IT
# shellcheck disable=SC1090
source "${FIREWALL_SCRIPT}"
parse_arguments
TEMP_DIR="${TEST_TMP}"
IP_RANGE_FILE_V4="${TEST_TMP}/allow4"
IP_RANGE_FILE_V6="${TEST_TMP}/allow6"
GEOBLOCK_IPV6=true
printf '198.18.0.0/24\n' >"${IP_RANGE_FILE_V4}"
printf '2001:db8::/32\n' >"${IP_RANGE_FILE_V6}"
apply_rules_nftables >/dev/null
nft list flowtable inet ip_blocker f | grep -Fq dkr0
nft -j list chain inet ip_blocker FORWARD | jq -e '.nftables[] | select(.chain.name == "FORWARD") | .chain.prio == 10' >/dev/null
# No custom NAT remains in the filter table, even with old empty settings.
nft -j list table inet ip_blocker | jq -e '[.nftables[] | .chain? | select(.type == "nat")] | length == 0' >/dev/null

# Model Docker-owned NAT separately, including published services. The script
# must neither remove these rules nor admit the public/DNAT reply direction.
nft -f - <<'EOF'
table inet docker_test {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 172.19.0.0/24 oifname wan0 masquerade
        ip6 saddr fd00:d0c:3::/64 oifname wan0 masquerade
    }
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname { wan0, wg0 } ip daddr 198.18.0.1 tcp dport 24444 dnat ip to 172.19.0.2:24242
        iifname { wan0, wg0 } ip6 daddr 2001:db8:2::1 tcp dport 24444 dnat ip6 to [fd00:d0c:3::2]:24242
    }
}
table inet observer {
    counter path4 {}
    counter path6 {}
    chain forward {
        type filter hook forward priority 20; policy accept;
        meta nfproto ipv4 counter name path4
        meta nfproto ipv6 counter name path6
    }
}
EOF
docker_before="$(nft list table inet docker_test)"
sed 's/define uplink = "eth0"/define uplink = "wan0"/' "${REPO_ROOT}/src/scripts/wireguard_nat.nft.example" >"${TEST_TMP}/vpn-nat.nft"
nft -f "${TEST_TMP}/vpn-nat.nft"
nft -f "${TEST_TMP}/vpn-nat.nft"
rule_count="$(nft -j list chain inet wg0_nat postrouting | jq '[.nftables[] | select(.rule)] | length')"
[[ "${rule_count}" == 2 ]]

cat >"${TEST_TMP}/peer.py" <<'PY'
import pathlib
import socket
import sys
import threading
import time

mode, family, protocol, host, port, *args = sys.argv[1:]
family = socket.AF_INET6 if family == '6' else socket.AF_INET
kind = socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM

def respond(connection, peer):
    with connection:
        while connection.recv(1):
            connection.sendall((peer[0] + '\n').encode())

with socket.socket(family, kind) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    if mode == 'server':
        sock.bind((host, int(port)))
        if protocol == 'tcp':
            sock.listen()
            pathlib.Path(args[0]).touch()
            while True:
                conn, peer = sock.accept()
                threading.Thread(target=respond, args=(conn, peer), daemon=True).start()
        else:
            pathlib.Path(args[0]).touch()
            while True:
                data, peer = sock.recvfrom(1024)
                sock.sendto((peer[0] + '\n').encode(), peer)
    else:
        sock.settimeout(2)
        sock.connect((host, int(port)))
        for _ in range(128):
            sock.sendall(b'x')
            reply = b''
            while not reply.endswith(b'\n'):
                part = sock.recv(256)
                assert part, 'unexpected EOF'
                reply += part
            assert reply.decode().strip() == args[0], reply
        if mode == 'hold':
            ready = pathlib.Path(args[1])
            ready.touch()
            while not pathlib.Path(str(ready) + '.ban').exists():
                time.sleep(0.01)
            sock.settimeout(0.5)
            try:
                sock.sendall(b'x')
                assert not sock.recv(256), 'established public connection bypassed the ban'
            except (TimeoutError, ConnectionError):
                pass
PY

wait_file() {
    for _ in {1..300}; do
        [[ -f "$1" ]] && return
        sleep 0.01
    done
    return 1
}
for server_ns in "${wan_ns}" "${docker_ns}"; do
    for family in 4 6; do
        [[ "${family}" == 4 ]] && bind_addr=0.0.0.0 || bind_addr=::
        for protocol in tcp udp; do
            ready="${TEST_TMP}/${server_ns}-${family}-${protocol}"
            nsenter -t "${server_ns}" -n python3 "${TEST_TMP}/peer.py" server "${family}" "${protocol}" "${bind_addr}" 24242 "${ready}" &
            pids+=("$!")
            wait_file "${ready}"
        done
    done
done

probe() {
    local client_ns="$1" family="$2" protocol="$3" destination="$4" port="$5" expected="$6" fast="$7"
    local packets
    nft reset counter inet observer "path${family}" >/dev/null
    if ! nsenter -t "${client_ns}" -n python3 "${TEST_TMP}/peer.py" client "${family}" "${protocol}" "${destination}" "${port}" "${expected}"; then
        printf 'Failed synthetic probe: IPv%s %s -> %s; expected source %s\n' "${family}" "${protocol}" "${destination}" "${expected}" >&2
        nsenter -t "${client_ns}" -n ip -6 route get "${destination}" >&2 || true
        nsenter -t "${client_ns}" -n ip -6 neigh >&2
        ip -6 route >&2
        ip -6 neigh >&2
        nft list table inet ip_blocker >&2
        return 1
    fi
    packets="$(nft -j list counter inet observer "path${family}" | jq '.nftables[] | select(.counter) | .counter.packets')"
    if [[ "${fast}" == true ]]; then
        ((packets < 64)) || {
            printf 'Expected offload, got %s classic-path packets\n' "${packets}" >&2
            return 1
        }
    else
        ((packets >= 128)) || {
            printf 'Unexpected offload of a public connection (%s packets)\n' "${packets}" >&2
            return 1
        }
    fi
    printf 'IPv%s %s: NAT/source=%s, accelerated=%s, classic packets=%s\n' "${family}" "${protocol}" "${expected}" "${fast}" "${packets}"
}
for protocol in tcp udp; do
    probe "${vpn_ns}" 4 "${protocol}" 198.18.0.2 24242 198.18.0.1 true
    probe "${vpn_ns}" 6 "${protocol}" 2001:db8:2::2 24242 2001:db8:2::1 true
    probe "${docker_ns}" 4 "${protocol}" 198.18.0.2 24242 198.18.0.1 true
    probe "${docker_ns}" 6 "${protocol}" 2001:db8:2::2 24242 2001:db8:2::1 true
done
probe "${wan_ns}" 4 tcp 198.18.0.1 24444 198.18.0.2 false
probe "${wan_ns}" 6 tcp 2001:db8:2::1 24444 2001:db8:2::2 false
# DNAT stays filtered even for a VPN origin, and direct-routed public access
# must not become eligible just because its reply comes from a trusted bridge.
probe "${vpn_ns}" 4 tcp 198.18.0.1 24444 10.200.1.2 false
probe "${wan_ns}" 4 tcp 172.19.0.2 24242 198.18.0.2 false
# Traffic to another internal segment keeps the original VPN address.
probe "${vpn_ns}" 4 tcp 172.19.0.2 24242 10.200.1.2 true
probe "${vpn_ns}" 6 tcp fd00:d0c:3::2 24242 fd00:d0c:1::2 true

# A trusted VPN global source outside GeoIP must pass unchanged (no NAT66).
nsenter -t "${vpn_ns}" -n ip -6 addr add 2001:db9:1::2/64 dev eth0 nodad
ip -6 route add 2001:db9:1::/64 dev wg0
nsenter -t "${vpn_ns}" -n ip -6 route replace default via fd00:d0c:1::1 src 2001:db9:1::2
# The synthetic wg0 is Ethernet, unlike a real point-to-point WireGuard link.
# Pin this new peer mapping so NDP timing cannot masquerade as a filter failure.
vpn_mac="$(nsenter -t "${vpn_ns}" -n ip -j link show eth0 | jq -r '.[0].address')"
ip -6 neigh replace 2001:db9:1::2 lladdr "${vpn_mac}" nud permanent dev wg0
probe "${vpn_ns}" 6 tcp 2001:db8:2::2 24242 2001:db9:1::2 true

nft 'add table inet ban_test'
nft 'add chain inet ban_test forward { type filter hook forward priority -1; policy accept; }'
for family in 4 6; do
    [[ "${family}" == 4 ]] && destination=198.18.0.1 || destination=2001:db8:2::1
    [[ "${family}" == 4 ]] && expected=198.18.0.2 || expected=2001:db8:2::2
    ready="${TEST_TMP}/hold-${family}"
    nsenter -t "${wan_ns}" -n python3 "${TEST_TMP}/peer.py" hold "${family}" tcp "${destination}" 24444 "${expected}" "${ready}" &
    client_pid=$!
    pids+=("${client_pid}")
    wait_file "${ready}"
    nft "add rule inet ban_test forward meta nfproto ipv${family} ct status dnat drop"
    touch "${ready}.ban"
    wait "${client_pid}"
done

# Atomic filter refresh must preserve VPN and Docker NAT owned elsewhere.
vpn_before="$(nft list table inet wg0_nat)"
apply_rules_nftables >/dev/null
vpn_after="$(nft list table inet wg0_nat)"
docker_after="$(nft list table inet docker_test)"
[[ "${vpn_after}" == "${vpn_before}" ]]
[[ "${docker_after}" == "${docker_before}" ]]
# Reject a malformed batch on the real kernel without altering any live table.
rules_before="$(nft -s list ruleset)"
set +e
(
    printf 'not-an-address\n' >"${IP_RANGE_FILE_V4}"
    apply_rules_nftables
) >"${TEST_TMP}/invalid-batch.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]]
grep -Fq 'failed validation' "${TEST_TMP}/invalid-batch.log"
rules_after="$(nft -s list ruleset)"
[[ "${rules_after}" == "${rules_before}" ]]
# The disposable network namespace owns cleanup, including on older nft versions.
printf 'Firewall NAT/offload kernel tests passed, including established-connection bans\n'
