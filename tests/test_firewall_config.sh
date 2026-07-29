#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

ip_blocker_env="${TEST_TMP}/ip_blocker.env"
cat >"${ip_blocker_env}" <<'EOF'
IP_BLOCKER_COUNTRIES='ripe:IT,FR;ipdeny:US,CA;nirsoft:DE'
IP_BLOCKER_PROVIDER=ignored_for_advanced_syntax
IP_BLOCKER_SSH_PORT=2222
IP_BLOCKER_FLOWTABLE_INTERFACES='en* br-*'
IP_BLOCKER_NAT_INTERFACES='eth* en*'
EOF
chmod 0600 "${ip_blocker_env}"
IP_BLOCKER_ENV_FILE="${ip_blocker_env}" \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" -C |
    grep -Fx 'ip_blocker configuration is valid' >/dev/null

geoip_env="${TEST_TMP}/geoip.env"
cat >"${geoip_env}" <<'EOF'
GEOIP_COUNTRIES='ripe:IT,FR;ipdeny:US,CA;nirsoft:DE'
GEOIP_REQUIRE_IPV6=false
EOF
chmod 0600 "${geoip_env}"
GEOIP_ENV_FILE="${geoip_env}" \
    "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh" -C |
    grep -Fx 'geo_ip_downloader configuration is valid' >/dev/null

printf 'IP_BLOCKER_COUNTRIES=unknown:US\n' >"${ip_blocker_env}"
if IP_BLOCKER_ENV_FILE="${ip_blocker_env}" \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" -C 2>/dev/null; then
    printf 'ip_blocker accepted an unknown provider\n' >&2
    exit 1
fi

printf 'GEOIP_COUNTRIES=unknown:US\n' >"${geoip_env}"
if GEOIP_ENV_FILE="${geoip_env}" \
    "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh" -C 2>/dev/null; then
    printf 'geo_ip_downloader accepted an unknown provider\n' >&2
    exit 1
fi

printf 'IP_BLOCKER_COUNTRIES=ipdeny:US\n' >"${ip_blocker_env}"
chmod 0666 "${ip_blocker_env}"
if IP_BLOCKER_ENV_FILE="${ip_blocker_env}" \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" -C 2>/dev/null; then
    printf 'ip_blocker accepted a world-writable environment file\n' >&2
    exit 1
fi
