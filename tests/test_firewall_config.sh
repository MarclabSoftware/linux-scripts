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
IP_BLOCKER_NAT_INTERFACES=''
EOF
chmod 0600 "${ip_blocker_env}"
IP_BLOCKER_ENV_FILE="${ip_blocker_env}" \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" -C |
    grep -Fx 'ip_blocker configuration is valid' >/dev/null

# A populated legacy NAT option cannot silently stop providing VPN egress.
printf "IP_BLOCKER_NAT_INTERFACES='eth* en*'\n" >>"${ip_blocker_env}"
if IP_BLOCKER_ENV_FILE="${ip_blocker_env}" \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" -C 2>/dev/null; then
    printf 'ip_blocker silently accepted retired generic NAT\n' >&2
    exit 1
fi

# ICMPv6 can follow extension headers (MLDv2 uses Hop-by-Hop), so nftables
# must inspect the resolved layer-4 protocol rather than the immediate header.
grep -F 'meta nfproto ipv6 meta l4proto ipv6-icmp accept' \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" >/dev/null
if grep -Eq 'ip6 nexthdr.*(icmpv6|ipv6-icmp)' \
    "${REPO_ROOT}/src/scripts/ip_blocker.sh" >/dev/null; then
    printf 'ip_blocker uses extension-header-unsafe ICMPv6 matching\n' >&2
    exit 1
fi

geoip_env="${TEST_TMP}/geoip.env"
cat >"${geoip_env}" <<'EOF'
GEOIP_COUNTRIES='ripe:IT,FR;ipdeny:US,CA;nirsoft:DE'
GEOIP_REQUIRE_IPV6=false
EOF
chmod 0600 "${geoip_env}"
GEOIP_ENV_FILE="${geoip_env}" \
    "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh" -C |
    grep -Fx 'geo_ip_downloader configuration is valid' >/dev/null

# Reject an impossible provider/family combination before any network I/O.
if GEOIP_ENV_FILE="${geoip_env}" \
    "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh" -C -6 true 2>/dev/null; then
    printf 'geo_ip_downloader accepted IPv6 with Nirsoft\n' >&2
    exit 1
fi

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
