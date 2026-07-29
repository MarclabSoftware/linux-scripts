#!/usr/bin/env bash

# Configuration-only checks for ethtool_optimizations.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPOSITORY_DIR}/src/scripts/ethtool_optimizations.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT

ETHTOOL_ENV_FILE=/nonexistent "${SCRIPT}" --check-config >/dev/null

env_file="${TEST_DIR}/ethtool.env"
cat >"${env_file}" <<'EOF'
ETHTOOL_INTERFACE_PATTERNS="en* eth*"
ETHTOOL_FEATURE_SETTINGS="rx-gro=invalid"
EOF
if ETHTOOL_ENV_FILE="${env_file}" "${SCRIPT}" --check-config >/dev/null 2>&1; then
    printf 'invalid ethtool feature state was accepted\n' >&2
    exit 1
fi

cat >"${env_file}" <<'EOF'
ETHTOOL_INTERFACE_PATTERNS="en*"
ETHTOOL_FEATURE_SETTINGS="rx-udp-gro-forwarding=on"
EOF
chmod 0666 "${env_file}"
if ETHTOOL_ENV_FILE="${env_file}" "${SCRIPT}" --check-config >/dev/null 2>&1; then
    printf 'writable ethtool environment file was accepted\n' >&2
    exit 1
fi

chmod 0600 "${env_file}"
mkdir -p -- "${TEST_DIR}/sys/class/net/enp1s0" "${TEST_DIR}/sys/class/net/lo"
printf 'ETHTOOL_SYSFS_NET_DIR=%s\n' "${TEST_DIR}/sys/class/net" >>"${env_file}"
dry_run_output="$(ETHTOOL_ENV_FILE="${env_file}" "${SCRIPT}" --dry-run)"
[[ "${dry_run_output}" == "ethtool -K enp1s0 rx-udp-gro-forwarding on" ]]

printf 'ethtool configuration tests passed\n'
