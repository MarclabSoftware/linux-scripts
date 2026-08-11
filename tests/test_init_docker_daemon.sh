#!/usr/bin/env bash

# Exercise Docker daemon configuration without touching the host daemon.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/docker_daemon.sh
. "${REPO_ROOT}/src/init/scripts/docker_daemon.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

CONFIG_DOCKER_EXPERIMENTAL=true
CONFIG_DOCKER_FIREWALL_BACKEND="nftables"
CONFIG_DOCKER_LOG_DRIVER="local"
CONFIG_DOCKER_IPV6=true
CONFIG_DOCKER_FIXED_CIDR_V6="2001:db8:1::/64"
validateDockerDaemonConfiguration

rendered="$(renderDockerDaemonConfiguration)"
grep -Fx '    "firewall-backend": "nftables",' <<<"${rendered}" >/dev/null
grep -Fx '    "fixed-cidr-v6": "2001:db8:1::/64"' \
    <<<"${rendered}" >/dev/null

CONFIG_DOCKER_EXPERIMENTAL=false
expect_failure validateDockerDaemonConfiguration
CONFIG_DOCKER_EXPERIMENTAL=true
CONFIG_DOCKER_FIXED_CIDR_V6="2001:db8::/129"
expect_failure validateDockerDaemonConfiguration
CONFIG_DOCKER_FIXED_CIDR_V6="2001:db8:1::/64"

DOCKER_ACTIVE=true
DOCKER_VALIDATE_FAIL=false
SYSTEMCTL_FAIL_NEXT_RESTART=false
SYSTEMCTL_LOG="${TEST_TMP}/systemctl.log"
: >"${SYSTEMCTL_LOG}"

dockerd() {
    [[ "$1" == --validate && "$2" == --config-file && -f "$3" ]]
    [[ "${DOCKER_VALIDATE_FAIL}" != true ]]
}

systemctl() {
    case "$1" in
        is-active)
            [[ "${DOCKER_ACTIVE}" == true && "${3:-}" == docker.service ]]
            ;;
        restart)
            printf 'restart %s\n' "$2" >>"${SYSTEMCTL_LOG}"
            if [[ "${SYSTEMCTL_FAIL_NEXT_RESTART}" == true ]]; then
                SYSTEMCTL_FAIL_NEXT_RESTART=false
                return 1
            fi
            ;;
        *) return 2 ;;
    esac
}

# Ownership is not material in this unprivileged temporary-directory test.
chown() {
    return 0
}

target="${TEST_TMP}/etc/docker/daemon.json"
mkdir -p -- "${target%/*}"
printf '{"old":true}\n' >"${target}"
configureDockerDaemon "${target}" >/dev/null
grep -Fx '    "log-driver": "local",' "${target}" >/dev/null
grep -Fx 'restart docker.service' "${SYSTEMCTL_LOG}" >/dev/null

# A failed restart restores the file that was present before the attempt.
printf '{"previous":true}\n' >"${target}"
SYSTEMCTL_FAIL_NEXT_RESTART=true
expect_failure configureDockerDaemon "${target}"
grep -Fx '{"previous":true}' "${target}" >/dev/null

# An invalid candidate never replaces the existing file.
DOCKER_VALIDATE_FAIL=true
expect_failure configureDockerDaemon "${target}"
grep -Fx '{"previous":true}' "${target}" >/dev/null

printf 'init Docker daemon tests passed\n'
