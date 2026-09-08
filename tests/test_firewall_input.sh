#!/usr/bin/env bash

# Generate production rules with mocked side effects, then exercise INPUT in
# disposable network namespaces. Never load these rules into the host firewall.
# shellcheck disable=SC2154,SC2034,SC2329
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
FIREWALL_SCRIPT="${IP_BLOCKER_TEST_SCRIPT:-${REPO_ROOT}/src/scripts/ip_blocker.sh}"
readonly FIREWALL_SCRIPT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export IP_BLOCKER_ENV_FILE="${TEST_TMP}/absent.env"
export IP_BLOCKER_COUNTRIES=IT IP_BLOCKER_SSH_PORT=22
export IP_BLOCKER_NAT_INTERFACES='' IP_BLOCKER_FLOWTABLE_INTERFACES=''

(
    # shellcheck disable=SC1090
    source "${FIREWALL_SCRIPT}"
    GEOBLOCK_IPV6=true
    printf '%s\n' '198.51.100.1-198.51.100.9' '198.51.100.10 -198.51.100.19' \
        '198.51.100.20- 198.51.100.29' '198.51.100.30 - 198.51.100.39' \
        '198.51.100.50-198.51.100.40' '198.51.100.256-198.51.100.255' \
        '198.51.100.1/24-198.51.100.9' '198.51.100.1--198.51.100.9' \
        '192.0.2.0/24' '2001:db8::/32' >"${TEST_TMP}/ranges"
    split_ip_families_from_file "${TEST_TMP}/ranges" "${TEST_TMP}/v4" "${TEST_TMP}/v6"
    printf '%s\n' '198.51.100.1 - 198.51.100.9' '198.51.100.10 - 198.51.100.19' \
        '198.51.100.20 - 198.51.100.29' '198.51.100.30 - 198.51.100.39' \
        '192.0.2.0/24' >"${TEST_TMP}/expected"
    diff -u "${TEST_TMP}/expected" "${TEST_TMP}/v4"
    grep -qxF '2001:db8::/32' "${TEST_TMP}/v6"

    # Capture the native generator without downloads or kernel changes.
    parse_arguments
    GEOBLOCK_IPV6=true
    TEMP_DIR="${TEST_TMP}"
    IP_RANGE_FILE_V4="${TEST_TMP}/allow4"
    IP_RANGE_FILE_V6="${TEST_TMP}/allow6"
    printf '198.18.0.0/24\n' >"${IP_RANGE_FILE_V4}"
    printf '2001:db8::/32\n' >"${IP_RANGE_FILE_V6}"
    nft() { [[ "$1" != list ]]; }
    apply_rules_nftables >/dev/null
)

for name in nft ip unshare nsenter python3; do
    command -v "${name}" >/dev/null || {
        printf 'Kernel tests require %s\n' "${name}"
        exit 77
    }
done
if [[ "${1:-}" != --isolated ]]; then
    unshare -Urn true 2>/dev/null || {
        printf 'Kernel tests require user/network namespaces\n'
        exit 77
    }
    export IP_BLOCKER_TEST_PARENT_NETNS
    IP_BLOCKER_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)"
    unshare -Urn bash "${BASH_SOURCE[0]}" --isolated
    exit
fi
test_netns="$(readlink /proc/self/ns/net)"
[[ -n "${IP_BLOCKER_TEST_PARENT_NETNS:-}" && "${test_netns}" != "${IP_BLOCKER_TEST_PARENT_NETNS}" ]]
ip link set lo up
unshare -n sleep 90 &
peer_pid=$!
trap 'kill "${peer_pid}" 2>/dev/null || true; wait "${peer_pid}" 2>/dev/null || true; rm -rf -- "${TEST_TMP}"' EXIT
for _ in {1..100}; do
    peer_netns="$(readlink "/proc/${peer_pid}/ns/net")"
    [[ "${peer_netns}" == "${test_netns}" ]] || break
    sleep 0.01
done
[[ "${peer_netns}" != "${test_netns}" ]]
ip link add incoming type veth peer name client
ip link set client netns "${peer_pid}"
ip addr add 198.18.0.1/24 dev incoming
ip -6 addr add 2001:db8::1/64 dev incoming nodad
ip link set incoming up
nsenter -t "${peer_pid}" -n ip addr add 198.18.0.2/24 dev client
nsenter -t "${peer_pid}" -n ip -6 addr add 2001:db8::2/64 dev client nodad
nsenter -t "${peer_pid}" -n ip link set client up

send_packets() {
    local -a sender=(nsenter -t "${peer_pid}" -n)
    [[ "${4:-}" != local ]] || sender=()
    "${sender[@]}" python3 - "$1" "$2" "$3" <<'PY'
import socket, sys
host, protocol, count = sys.argv[1:]
family = socket.AF_INET6 if ':' in host else socket.AF_INET
sockets = []
for _ in range(int(count)):
    s = socket.socket(family, socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM)
    sockets.append(s)
    s.setblocking(False)
    if protocol == 'tcp':
        s.connect_ex((host, 22))
    else:
        s.sendto(b'test', (host, 25252))
for s in sockets:
    s.close()
PY
}

check_tcp_exchange() {
    python3 - "${peer_pid}" "$1" <<'PY'
import socket, subprocess, sys
pid, host = sys.argv[1:]
family = socket.AF_INET6 if ':' in host else socket.AF_INET
client = None
with socket.socket(family, socket.SOCK_STREAM) as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, 22))
    server.listen()
    server.settimeout(3)
    try:
        client = subprocess.Popen(['nsenter', '-t', pid, '-n', 'python3', '-c',
            'import socket,sys; s=socket.create_connection((sys.argv[1],22),2); '
            's.sendall(b"ok"); assert s.recv(2)==b"ok"; s.close()', host])
        conn, _ = server.accept()
        with conn:
            conn.settimeout(2)
            assert conn.recv(2) == b'ok'
            conn.sendall(b'ok')
        assert client.wait(timeout=3) == 0
    finally:
        if client is not None:
            if client.poll() is None: client.kill()
            client.wait()
PY
}

# Use the complete native ruleset, with all normal source/rate guards intact.
nft -f "${TEST_TMP}/nft_ruleset.nft"
check_tcp_exchange 198.18.0.1
check_tcp_exchange 2001:db8::1
# An accept verdict here must not bypass the later host firewall.
nft -f - <<'EOF'
table inet host_policy {
    counter udp_seen {}
    chain input {
        type filter hook input priority filter; policy drop;
        meta l4proto ipv6-icmp accept
        udp dport 25252 counter name udp_seen drop
        tcp dport 22 accept
    }
}
EOF
for host in 198.18.0.1 2001:db8::1; do
    nft reset counter inet host_policy udp_seen >/dev/null
    send_packets "${host}" udp 1
    nft -j list counter inet host_policy udp_seen | python3 -c '
import json, sys
counts = [o["counter"]["packets"] for o in json.load(sys.stdin)["nftables"] if "counter" in o]
assert counts == [1], counts
'
done
for host in 127.0.0.1 ::1; do
    nft reset counter inet host_policy udp_seen >/dev/null
    send_packets "${host}" udp 1 local
    nft -j list counter inet host_policy udp_seen | python3 -c '
import json, sys
assert [o["counter"]["packets"] for o in json.load(sys.stdin)["nftables"] if "counter" in o] == [1]
'
done
check_tcp_exchange 198.18.0.1
check_tcp_exchange 2001:db8::1
send_packets 198.18.0.1 tcp 100
send_packets 2001:db8::1 tcp 100
nft -j list chain inet ip_blocker SSH_RATE_DROP | python3 -c '
import json, sys
logs, drops = [], 0
for obj in json.load(sys.stdin)["nftables"]:
    expr = obj.get("rule", {}).get("expr", [])
    count = sum(e.get("counter", {}).get("packets", 0) for e in expr)
    if any("log" in e for e in expr): logs.append(count)
    if any("drop" in e for e in expr): drops += count
assert len(logs) == 2 and all(0 < n <= 5 for n in logs), logs
assert drops >= 100 and drops > sum(logs), (drops, logs)
'
# Trusted bridge/tunnel inputs, including global IPv6 sources, bypass meters.
drop_count() {
    nft -j list chain inet ip_blocker SSH_RATE_DROP | python3 -c '
import json, sys
print(sum(e.get("counter", {}).get("packets", 0) for o in json.load(sys.stdin)["nftables"]
    for e in o.get("rule", {}).get("expr", []) if any("drop" in x for x in o.get("rule", {}).get("expr", []))))
'
}
before_drops="$(drop_count)"
for trusted_interface in wg0 docker0 br-test; do
    ip link set incoming name "${trusted_interface}"
    send_packets 198.18.0.1 tcp 100
    send_packets 2001:db8::1 tcp 100
    after_drops="$(drop_count)"
    [[ "${after_drops}" == "${before_drops}" ]]
    # The later host policy still applies to trusted bridge/tunnel ingress.
    nft reset counter inet host_policy udp_seen >/dev/null
    send_packets 198.18.0.1 udp 1
    nft -j list counter inet host_policy udp_seen | python3 -c '
import json, sys
assert [o["counter"]["packets"] for o in json.load(sys.stdin)["nftables"] if "counter" in o] == [1]
'
    ip link set "${trusted_interface}" name incoming
done

# Public sources outside GeoIP must be dropped even after the log cap is used.
ip addr add 203.0.113.1/24 dev incoming
ip -6 addr add 2001:db9:bad::1/64 dev incoming nodad
nsenter -t "${peer_pid}" -n ip addr add 203.0.113.2/24 dev client
nsenter -t "${peer_pid}" -n ip -6 addr add 2001:db9:bad::2/64 dev client nodad
host_mac="$(ip -o link show incoming | awk '{ for(i=1;i<=NF;i++) if($i=="link/ether") print $(i+1) }')"
nsenter -t "${peer_pid}" -n ip neigh replace 203.0.113.1 lladdr "${host_mac}" nud permanent dev client
nsenter -t "${peer_pid}" -n ip -6 neigh replace 2001:db9:bad::1 lladdr "${host_mac}" nud permanent dev client
send_packets 203.0.113.1 udp 100
send_packets 2001:db9:bad::1 udp 100
nft -j list chain inet ip_blocker GEOIP_DROP | python3 -c '
import json, sys
logs, drops = [], 0
for obj in json.load(sys.stdin)["nftables"]:
    expr = obj.get("rule", {}).get("expr", [])
    count = sum(e.get("counter", {}).get("packets", 0) for e in expr)
    if any("log" in e for e in expr): logs.append(count)
    if any("drop" in e for e in expr): drops += count
assert len(logs) == 2 and all(0 < n <= 10 for n in logs), logs
assert drops == 200, drops
'

# Keep production rules intact, reducing only capacity/timeout for a bounded test.
python3 - "${peer_pid}" "${TEST_TMP}/nft_ruleset.nft" <<'PY'
import json, pathlib, socket, subprocess, sys, time
pid, config_path = sys.argv[1:]
config = pathlib.Path(config_path).read_text()
assert config.count('flags dynamic, timeout; timeout 1m; size 65536;') == 2
config = config.replace('timeout 1m; size 65536;', 'timeout 2s; gc-interval 100ms; size 2;')
subprocess.run(['nft', 'delete', 'table', 'inet', 'ip_blocker'], check=True)
subprocess.run(['nft', '-f', '-'], input=config, text=True, check=True)

for family, host, set_name, seeds in [
    (socket.AF_INET, '198.18.0.1', 'ssh_meter_v4', ['203.0.113.1', '203.0.113.2']),
    (socket.AF_INET6, '2001:db8::1', 'ssh_meter_v6', ['2001:db8:ffff::1', '2001:db8:ffff::2']),
]:
    # Hold a working connection through saturation: established traffic must survive.
    with socket.socket(family, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, 22)); server.listen(); server.settimeout(3)
        client_code = '''import socket,sys
s=socket.create_connection((sys.argv[1],22),2)
s.settimeout(3)
assert s.recv(2)==b'ok'
s.sendall(b'ok')
s.close()
'''
        client = subprocess.Popen(['nsenter', '-t', pid, '-n', 'python3', '-c', client_code, host])
        try:
            conn, _ = server.accept()
            with conn:
                conn.settimeout(3)
                subprocess.run(['nft', 'flush', 'set', 'inet', 'ip_blocker', set_name], check=True)
                for seed in seeds:
                    # Occupy slots without a per-element expression: older nft
                    # parsers support this too; seed addresses never send traffic.
                    subprocess.run(['nft', 'add', 'element', 'inet', 'ip_blocker', set_name,
                        '{ '+seed+' timeout 2s }'], check=True)
                # Neither a new source nor repeated attempts may bypass a full meter.
                blocked_code = '''import socket,sys
for _ in range(3):
    try: s=socket.create_connection((sys.argv[1],22),0.15)
    except TimeoutError: continue
    else: s.close(); raise AssertionError('full meter accepted a new connection')
'''
                subprocess.run(['nsenter', '-t', pid, '-n', 'python3', '-c', blocked_code, host], check=True)
                conn.sendall(b'ok')
                assert conn.recv(2) == b'ok'
            assert client.wait(timeout=3) == 0
        finally:
            if client.poll() is None: client.kill()
            client.wait()

    # Expiration frees the occupied slots without a ruleset reload.
    deadline = time.monotonic() + 5
    while True:
        data = json.loads(subprocess.check_output(['nft', '-j', 'list', 'set', 'inet', 'ip_blocker', set_name]))
        entries = [e for obj in data['nftables'] for e in obj.get('set', {}).get('elem', [])]
        if not entries: break
        assert time.monotonic() < deadline, 'inactive meter entries did not expire'
        time.sleep(0.1)
PY
check_tcp_exchange 198.18.0.1
check_tcp_exchange 2001:db8::1
printf 'Firewall INPUT, SSH logging/saturation/expiry and range tests passed\n'
