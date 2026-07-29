#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP

cleanup() {
    rm -rf -- "${TEST_TMP}"
}
trap cleanup EXIT

mkdir -p -- "${TEST_TMP}/bin"

cat >"${TEST_TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG}"
[[ "${1:-} ${2:-}" != "network inspect" ]]
EOF
chmod 0755 "${TEST_TMP}/bin/docker"

export DOCKER_CALL_LOG="${TEST_TMP}/docker.calls"
export PATH="${TEST_TMP}/bin:${PATH}"

DOCKER_NETWORK_NAME=test_bridge \
    DOCKER_NETWORK_DRIVER=bridge \
    DOCKER_NETWORK_IPV4_SUBNET=172.30.0.0/24 \
    DOCKER_NETWORK_IPV4_GATEWAY=172.30.0.1 \
    DOCKER_NETWORK_ENABLE_IPV6=1 \
    DOCKER_NETWORK_IPV6_SUBNET=fd00:30::/64 \
    DOCKER_NETWORK_IPV6_GATEWAY=fd00:30::1 \
    "${REPO_ROOT}/src/scripts/docker_network.sh"

grep -Fx 'network inspect test_bridge' "${DOCKER_CALL_LOG}" >/dev/null
grep -Fx 'network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 --ipv6 --subnet fd00:30::/64 --gateway fd00:30::1 test_bridge' "${DOCKER_CALL_LOG}" >/dev/null

if DOCKER_NETWORK_ENABLE_IPV6=invalid "${REPO_ROOT}/src/scripts/docker_network.sh" 2>/dev/null; then
    printf 'invalid IPv6 setting was unexpectedly accepted\n' >&2
    exit 1
fi
