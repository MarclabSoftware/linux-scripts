#!/usr/bin/env bash

# Exercise GeoIP parsing/publication and iprange on synthetic data only.
# shellcheck disable=SC2034
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export GEOIP_ENV_FILE="${TEST_TMP}/absent.env"
# shellcheck source=src/scripts/geo_ip_downloader.sh
source "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh"
TEMP_DIR="${TEST_TMP}"
STAGING_V4="${TEST_TMP}/staging4"
STAGING_V6="${TEST_TMP}/staging6"
ALLOW_DIR_V4="${TEST_TMP}/cache4"
ALLOW_DIR_V6="${TEST_TMP}/cache6"
mkdir -p -- "${STAGING_V4}" "${STAGING_V6}" "${ALLOW_DIR_V4}" "${ALLOW_DIR_V6}"

printf '# comment\r\n 120.229.26.013 ; note\r\n192.000.002.008/032\n198.051.100.008 - 198.051.100.010\n' >"${TEST_TMP}/fresh"
printf '%s\n' '120.229.26.13' '192.0.2.8/32' '198.51.100.8 - 198.51.100.10' >"${TEST_TMP}/expected4"
validate_and_move_generated_file "${TEST_TMP}/fresh" "${STAGING_V4}/fresh.list.v4" test
diff -u "${TEST_TMP}/expected4" "${STAGING_V4}/fresh.list.v4"
[[ ! -e "${TEST_TMP}/fresh" && ! -e "${TEST_TMP}/fresh.normalized" ]]
printf '%s\n' '2001:db8::/48' '::ffff:192.000.002.008/128' >"${TEST_TMP}/fresh6"
validate_and_move_generated_file "${TEST_TMP}/fresh6" "${STAGING_V6}/fresh.list.v6" test
printf '%s\n' '2001:db8::/48' '::ffff:192.0.2.8/128' >"${TEST_TMP}/expected6"
diff -u "${TEST_TMP}/expected6" "${STAGING_V6}/fresh.list.v6"

# Invalid/unsafe input must not replace a previously published file.
for bad in '0.0.0.0/0' '001.2.3.4/000' '000.000.000.000' \
    '0.0.0.0 - 255.255.255.255' '198.51.100.256' '2001:db8::1' 'invalid row'; do
    printf '192.0.2.1\n%s\n' "${bad}" >"${TEST_TMP}/bad"
    validate_and_move_generated_file "${TEST_TMP}/bad" "${STAGING_V4}/fresh.list.v4" test
    diff -u "${TEST_TMP}/expected4" "${STAGING_V4}/fresh.list.v4"
    [[ ! -e "${TEST_TMP}/bad.normalized" ]]
done
# Validation is a predicate; write failures must be returned explicitly.
# shellcheck disable=SC2310
if validate_generated_list_file "${STAGING_V4}/fresh.list.v4" v4 /dev/full 2>/dev/null; then
    printf 'normalization ignored a write failure\n' >&2
    exit 1
fi

# Cached input is normalized without mutating it or refreshing its age.
printf '120.229.26.013\n' >"${ALLOW_DIR_V4}/it.ipdeny.list.v4"
touch -t 202001010000 "${ALLOW_DIR_V4}/it.ipdeny.list.v4"
restore_missing_expected_lists v4 it.ipdeny.list.v4
grep -qxF '120.229.26.13' "${STAGING_V4}/it.ipdeny.list.v4"
grep -qxF '120.229.26.013' "${ALLOW_DIR_V4}/it.ipdeny.list.v4"
staged_time="$(stat -c %Y "${STAGING_V4}/it.ipdeny.list.v4")"
cached_time="$(stat -c %Y "${ALLOW_DIR_V4}/it.ipdeny.list.v4")"
[[ "${staged_time}" == "${cached_time}" ]]
printf '192.0.2.0/24\n' >"${ALLOW_DIR_V4}/it.ripe.list.v4"
restore_missing_expected_lists v4 it.ripe.list.v4
[[ "${MISSING_EXPECTED_FILES[*]}" == v4:it.ripe.list.v4 ]]
[[ ! -e "${STAGING_V4}/it.ripe.list.v4" ]]
MISSING_EXPECTED_FILES=()
printf '192.000.002.008 - 192.000.002.010\n' >"${ALLOW_DIR_V4}/it.ripe.list.v4"
restore_missing_expected_lists v4 it.ripe.list.v4
grep -qxF '192.0.2.8 - 192.0.2.10' "${STAGING_V4}/it.ripe.list.v4"
[[ ${#MISSING_EXPECTED_FILES[@]} == 0 ]]
printf '192.0.2.1\ninvalid\n' >"${ALLOW_DIR_V4}/bad.list.v4"
restore_missing_expected_lists v4 bad.list.v4
[[ ! -e "${STAGING_V4}/bad.list.v4" ]]

# Run the actual downloader entrypoint offline: old CIDR caches cannot be
# repaired without the source database, while new range caches remain usable.
offline_root="${TEST_TMP}/offline"
mkdir -p -- "${offline_root}/v4" "${offline_root}/v6" "${TEST_TMP}/bin"
printf '#!/bin/sh\nexit 22\n' >"${TEST_TMP}/bin/curl"
chmod 0700 -- "${TEST_TMP}/bin/curl"
for cache in '130.192.96.0/18' '130.192.96.0 - 130.192.159.255'; do
    printf '%s\n' "${cache}" >"${offline_root}/v4/it.ripe.list.v4"
    if PATH="${TEST_TMP}/bin:${PATH}" GEOIP_MAX_DOWNLOAD_RETRIES=1 DNS_SERVERS='' \
        bash "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh" -c ripe:IT -6 false -o "${offline_root}" \
        >"${TEST_TMP}/offline.output" 2>&1; then
        [[ "${cache}" == *' - '* ]]
    else
        [[ "${cache}" == */* ]]
        grep -Fq 'Missing required Geo-IP list' "${TEST_TMP}/offline.output"
    fi
    grep -qxF "${cache}" "${offline_root}/v4/it.ripe.list.v4"
done

# The complete RIPE function reads this synthetic, already downloaded database.
# Include a nonaligned power-of-two count, a non-power-of-two count, one host,
# a /8 boundary crossing and the highest IPv4 address.
cat >"${TEMP_DIR}/delegated-ripencc-latest" <<'EOF'
ripencc|IT|ipv4|130.192.96.0|16384|20260101|allocated
ripencc|IT|ipv4|151.3.0.0|5046272|20260101|assigned
ripencc|IT|ipv4|192.000.002.008|3|20260101|allocated
ripencc|IT|ipv4|127.255.255.255|2|20260101|allocated
ripencc|IT|ipv4|255.255.255.255|1|20260101|assigned
ripencc|IT|ipv6|2001:db8::|32|20260101|allocated
ripencc|FR|ipv4|203.0.113.0|256|20260101|allocated
ripencc|IT|ipv4|203.0.113.0|256|20260101|reserved
EOF
REQUIRE_IPV6_LISTS=true
download_provider_ripe IT
printf '%s\n' '130.192.96.0 - 130.192.159.255' '151.3.0.0 - 151.79.255.255' \
    '192.0.2.8 - 192.0.2.10' '127.255.255.255 - 128.0.0.0' \
    '255.255.255.255 - 255.255.255.255' >"${TEST_TMP}/ripe-expected"
diff -u "${TEST_TMP}/ripe-expected" "${STAGING_V4}/it.ripe.list.v4"
grep -qxF '2001:db8::/32' "${STAGING_V6}/it.ripe.list.v6"
cp -- "${TEMP_DIR}/delegated-ripencc-latest" "${TEST_TMP}/valid-ripe"
for allocation in '192.0.2.0|0' '192.0.2.0|-1' '192.0.2.0|1.5' \
    '255.255.255.255|2' '256.0.0.0|1' '192.0.2.0|abc'; do
    cp -- "${TEST_TMP}/valid-ripe" "${TEMP_DIR}/delegated-ripencc-latest"
    printf 'ripencc|IT|ipv4|%s|20260101|allocated\n' "${allocation}" >>"${TEMP_DIR}/delegated-ripencc-latest"
    # Expected error deliberately tested in a subshell; no publication on failure.
    # shellcheck disable=SC2310
    if (download_provider_ripe IT) >/dev/null 2>&1; then
        printf 'RIPE accepted invalid allocation: %s\n' "${allocation}" >&2
        exit 1
    fi
    diff -u "${TEST_TMP}/ripe-expected" "${STAGING_V4}/it.ripe.list.v4"
done

command -v iprange >/dev/null || {
    printf 'GeoIP iprange test skipped: iprange is unavailable\n'
    exit 77
}
# Known exact CIDRs independently describe the nonaligned allocation.
printf '130.192.96.0/19\n130.192.128.0/19\n' >"${TEST_TMP}/cidrs"
printf '130.192.96.0 - 130.192.159.255\n' >"${TEST_TMP}/range"
iprange -4 "${TEST_TMP}/range" >"${TEST_TMP}/actual"
diff -u "${TEST_TMP}/cidrs" "${TEST_TMP}/actual"
for family in 4 6; do
    staging_var="STAGING_V${family}"
    iprange "-${family}" "${TEST_TMP}/expected${family}" --except "${!staging_var}/fresh.list.v${family}" >"${TEST_TMP}/remaining"
    [[ ! -s "${TEST_TMP}/remaining" ]]
done
printf 'GeoIP normalization, exact RIPE ranges and cache tests passed\n'
