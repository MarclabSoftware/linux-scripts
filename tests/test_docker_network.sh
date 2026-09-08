#!/usr/bin/env bash

# Check creation and immutable compatibility checks with a fake Docker client.
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
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG}"
case "${1:-} ${2:-}" in
    'network inspect')
        case "${DOCKER_TEST_MODE:-missing}" in
            missing | daemon-error | unreadable) exit 1 ;;
            driver) printf 'overlay\ntrue\n172.30.0.0/24|172.30.0.1\nfd00:30::/64|fd00:30::1\n' ;;
            ipv6) printf 'bridge\nfalse\n172.30.0.0/24|172.30.0.1\nfd00:30::/64|fd00:30::1\n' ;;
            subnet) printf 'bridge\ntrue\n172.31.0.0/24|172.31.0.1\nfd00:30::/64|fd00:30::1\n' ;;
            gateway) printf 'bridge\ntrue\n172.30.0.0/24|172.30.0.2\nfd00:30::/64|fd00:30::1\n' ;;
            gateway6) printf 'bridge\ntrue\n172.30.0.0/24|172.30.0.1\nfd00:30::/64|fd00:30::2\n' ;;
            *) printf 'bridge\ntrue\n172.30.0.0/24|172.30.0.1\nfd00:30::/64|fd00:30::1\n' ;;
        esac
        ;;
    'network ls')
        [[ "${DOCKER_TEST_MODE:-missing}" != daemon-error ]] || exit 1
        [[ "${DOCKER_TEST_MODE:-missing}" != unreadable ]] || printf 'test_bridge\n'
        ;;
    'network create') ;;
    *) exit 99 ;;
esac
EOF
chmod 0755 "${TEST_TMP}/bin/docker"

export DOCKER_CALL_LOG="${TEST_TMP}/docker.calls"
export PATH="${TEST_TMP}/bin:${PATH}"
export DOCKER_NETWORK_ENV_FILE=/nonexistent

export DOCKER_NETWORK_NAME=test_bridge \
    DOCKER_NETWORK_DRIVER=bridge \
    DOCKER_NETWORK_IPV4_SUBNET=172.30.0.0/24 \
    DOCKER_NETWORK_IPV4_GATEWAY=172.30.0.1 \
    DOCKER_NETWORK_ENABLE_IPV6=1 \
    DOCKER_NETWORK_IPV6_SUBNET=fd00:30::/64 \
    DOCKER_NETWORK_IPV6_GATEWAY=fd00:30::1
"${REPO_ROOT}/src/scripts/docker_network.sh"

grep -F 'network inspect --format ' "${DOCKER_CALL_LOG}" >/dev/null
grep -Fx 'network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 --ipv6 --subnet fd00:30::/64 --gateway fd00:30::1 test_bridge' "${DOCKER_CALL_LOG}" >/dev/null

if DOCKER_NETWORK_ENABLE_IPV6=invalid "${REPO_ROOT}/src/scripts/docker_network.sh" 2>/dev/null; then
    printf 'invalid IPv6 setting was unexpectedly accepted\n' >&2
    exit 1
fi

for DOCKER_TEST_MODE in existing driver ipv6 subnet gateway gateway6 daemon-error unreadable; do
    export DOCKER_TEST_MODE
    : >"${DOCKER_CALL_LOG}"
    if "${REPO_ROOT}/src/scripts/docker_network.sh" >/dev/null 2>&1; then
        [[ "${DOCKER_TEST_MODE}" == existing ]]
    else
        [[ "${DOCKER_TEST_MODE}" != existing ]]
    fi
    if grep -Fq 'network create' "${DOCKER_CALL_LOG}"; then
        printf 'existing or unreadable network triggered creation\n' >&2
        exit 1
    fi
    count="$(grep -cF 'network inspect ' "${DOCKER_CALL_LOG}")"
    [[ "${count}" == 1 ]]
done

# Unspecified IPAM and IPv6 settings do not constrain an existing bridge.
DOCKER_TEST_MODE=existing env -u DOCKER_NETWORK_ENABLE_IPV6 -u DOCKER_NETWORK_IPV4_SUBNET \
    -u DOCKER_NETWORK_IPV4_GATEWAY -u DOCKER_NETWORK_IPV6_SUBNET -u DOCKER_NETWORK_IPV6_GATEWAY \
    "${REPO_ROOT}/src/scripts/docker_network.sh"
printf 'Docker network tests passed\n'
