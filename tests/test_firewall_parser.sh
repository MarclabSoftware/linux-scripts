#!/usr/bin/env bash

# Parse synthetic mixed feeds and run iprange only; never touch firewall rules.
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export IP_BLOCKER_ENV_FILE="${TEST_TMP}/absent.env"
# shellcheck source=src/scripts/ip_blocker.sh
source "${REPO_ROOT}/src/scripts/ip_blocker.sh"

cat >"${TEST_TMP}/mixed" <<'EOF'
120.229.26.013
81.183.41.001
192.000.002.008/032
198.051.100.008 - 198.051.100.010
2001:db8::13
2001:db8:1::/126
198.51.100.256
198.51.100.010-198.51.100.008
EOF
printf '%s\n' '120.229.26.13' '81.183.41.1' '192.0.2.8/32' \
    '198.51.100.8 - 198.51.100.10' >"${TEST_TMP}/expected4"
printf '%s\n' '2001:db8::13' '2001:db8:1::/126' >"${TEST_TMP}/expected6"
for GEOBLOCK_IPV6 in true false; do
    split_ip_families_from_file "${TEST_TMP}/mixed" "${TEST_TMP}/v4-${GEOBLOCK_IPV6}" "${TEST_TMP}/v6-${GEOBLOCK_IPV6}"
    diff -u "${TEST_TMP}/expected4" "${TEST_TMP}/v4-${GEOBLOCK_IPV6}"
done
diff -u "${TEST_TMP}/expected6" "${TEST_TMP}/v6-true"
[[ ! -s "${TEST_TMP}/v6-false" ]]

command -v iprange >/dev/null || {
    printf 'iprange integration test skipped: iprange is unavailable\n'
    exit 77
}
# Compare actual merged sets and subtraction, not just the parser output.
for family in 4 6; do
    iprange "-${family}" "${TEST_TMP}/expected${family}" >"${TEST_TMP}/expected-set"
    iprange "-${family}" "${TEST_TMP}/v${family}-true" >"${TEST_TMP}/actual-set"
    diff -u "${TEST_TMP}/expected-set" "${TEST_TMP}/actual-set"
    iprange "-${family}" "${TEST_TMP}/expected${family}" --except "${TEST_TMP}/v${family}-true" >"${TEST_TMP}/remaining"
    [[ ! -s "${TEST_TMP}/remaining" ]]
done
printf 'Mixed-family decimal IPv4 parser and iprange tests passed\n'
