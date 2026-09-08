#!/usr/bin/env bash

# Failure injection intentionally calls checked helpers in conditional contexts.
# Test doubles and per-subshell sidecars do not alter the parent environment.
# shellcheck disable=SC2030,SC2329

# Exercise downloads, DNS caching, IPv6 policy and native nftables recovery without networking.
# Test doubles are called by the sourced scripts.
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export IP_BLOCKER_ENV_FILE=/nonexistent GEOIP_ENV_FILE=/nonexistent

for script in ip_blocker geo_ip_downloader; do
    (
        # shellcheck disable=SC1090
        source "${REPO_ROOT}/src/scripts/${script}.sh"
        # Each script gets a separate resolver configuration and cache.
        # shellcheck disable=SC2030
        export DNS_SERVERS=192.0.2.53
        # shellcheck disable=SC2329
        dig() {
            printf '%s\n' "$*" >>"${TEST_TMP}/dns-${script}"
            [[ "${*: -1}" != A ]] || printf 'edge.lists.example.net.\n192.0.2.80\n'
            [[ "${*: -1}" != AAAA ]] || printf ';; communications error: timed out\n2001:db8::80\n'
        }
        options_one="" options_two=""
        build_resolve_options_for_url https://lists.example/one options_one
        build_resolve_options_for_url https://lists.example/two options_two
        count="$(wc -l <"${TEST_TMP}/dns-${script}")"
        [[ "${count}" == 2 && "${options_one}" == "${options_two}" ]]
        [[ "${options_one}" == '--resolve lists.example:443:192.0.2.80,[2001:db8::80]' ]]
    )
done

for mode in index_partial index_markup list_partial no_cache; do
    (
        IP_BLOCKER_LIST_DIR="${TEST_TMP}/${mode}"
        # shellcheck source=src/scripts/ip_blocker.sh
        source "${REPO_ROOT}/src/scripts/ip_blocker.sh"
        TEMP_DIR="${IP_LIST_DIR}/stage"
        mkdir -p -- "${TEMP_DIR}" "${BLOCK_LIST_DIR}"
        source_url=https://lists.example/one
        printf '%s\n' "${source_url}" >"${BLOCK_LIST_FILE_NAME}"
        key="$(blocklist_cache_name_from_url "${source_url}")"
        [[ "${mode}" == no_cache ]] || printf '192.0.2.1\n' >"${BLOCK_LIST_DIR}/${key}"
        curl() {
            local output="" url=""
            while (($#)); do
                case "$1" in
                    -o)
                        output="$2"
                        shift
                        ;;
                    https://*) url="$1" ;;
                    *) ;;
                esac
                shift
            done
            if [[ "${url}" == "${BLOCK_LIST_URL}" ]]; then
                case "${mode}" in
                    index_partial)
                        printf 'https://partial.example/' >"${output}"
                        return 18
                        ;;
                    index_markup)
                        printf '<html>error</html>\n' >"${output}"
                        return 0
                        ;;
                    *) printf '%s\n' "${source_url}" >"${output}" ;;
                esac
            else
                [[ "${url}" == "${source_url}" ]] || return 99
                printf '198.51.100.9\n' >"${output}"
                [[ "${mode}" != list_partial && "${mode}" != no_cache ]] || return 18
            fi
        }
        # shellcheck disable=SC2310
        if download_blocklists >"${TEST_TMP}/${mode}.output" 2>&1; then
            [[ "${mode}" != no_cache ]]
        else
            [[ "${mode}" == no_cache ]]
        fi
        grep -qxF "${source_url}" "${BLOCK_LIST_FILE_NAME}"
        case "${mode}" in
            list_partial) grep -qxF 192.0.2.1 "${BLOCK_LIST_DIR}/${key}" ;;
            no_cache) [[ ! -e "${BLOCK_LIST_DIR}/${key}" ]] ;;
            *) grep -qxF 198.51.100.9 "${BLOCK_LIST_DIR}/${key}" ;;
        esac
    )
done

(
    # A failed parser, including one in an earlier batch, retains both families.
    # Each scenario owns its list root in a subshell.
    # shellcheck disable=SC2030
    IP_BLOCKER_LIST_DIR="${TEST_TMP}/parse"
    # shellcheck source=src/scripts/ip_blocker.sh
    source "${REPO_ROOT}/src/scripts/ip_blocker.sh"
    TEMP_DIR="${IP_LIST_DIR}/stage"
    mkdir -p -- "${TEMP_DIR}" "${BLOCK_LIST_DIR}" "${BLOCK_LIST_DIR_V4}" "${BLOCK_LIST_DIR_V6}"
    printf 'old-v4\n' >"${BLOCK_LIST_DIR_V4}/old"
    printf 'old-v6\n' >"${BLOCK_LIST_DIR_V6}/old"
    for n in {1..10}; do printf '192.0.2.1\n' >"${BLOCK_LIST_DIR}/list-${n}"; done
    awk() {
        [[ "${*: -1}" != */list-1 ]] || return 23
        command awk "$@"
    }
    # Run in a new shell so the real failure handler may exit normally.
    set +e
    (
        set -e
        separate_ip_families
    ) >/dev/null 2>&1
    status=$?
    set -e
    [[ "${status}" != 0 ]]
    grep -qxF old-v4 "${BLOCK_LIST_DIR_V4}/old"
    grep -qxF old-v6 "${BLOCK_LIST_DIR_V6}/old"
)

(
    # A firewall CLI requirement must override a downloader sidecar's default.
    printf 'GEOIP_REQUIRE_IPV6=false\nGEOIP_ALLOW_ROOT_DIR=/wrong-path\n' >"${TEST_TMP}/geoip.env"
    chmod 0600 -- "${TEST_TMP}/geoip.env"
    GEOIP_ENV_FILE="${TEST_TMP}/geoip.env"
    # shellcheck source=src/scripts/geo_ip_downloader.sh
    source "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh"
    parse_arguments -c ipdeny:IT -6 true -o "${TEST_TMP}/parent-policy"
    [[ "${REQUIRE_IPV6_LISTS}" == true ]]
    [[ "${ALLOW_DIR_V4}" == "${TEST_TMP}/parent-policy/v4" ]]
    [[ "${ALLOW_DIR_V6}" == "${TEST_TMP}/parent-policy/v6" ]]
    printf '0.0.0.0/0\n' >"${TEST_TMP}/dangerous"
    validate_and_move_generated_file "${TEST_TMP}/dangerous" "${TEST_TMP}/published" test \
        2>"${TEST_TMP}/validation.output"
    [[ ! -e "${TEST_TMP}/published" && ! -e "${TEST_TMP}/dangerous" ]]
    grep -Fq 'DANGEROUS entry' "${TEST_TMP}/validation.output"

    # Noncanonical /0 and differently spaced catch-all ranges are equally unsafe.
    for entry in '192.0.2.1/0' '2001:db8::/00' '0.0.0.0  -  255.255.255.255'; do
        printf '%s\n' "${entry}" >"${TEST_TMP}/dangerous"
        # shellcheck disable=SC2310
        if validate_generated_list_file "${TEST_TMP}/dangerous"; then exit 1; else status=$?; fi
        [[ "${status}" == 2 ]]
    done
    # Correct syntax in the wrong address family cannot replace a valid cache.
    printf '192.0.2.0/24\n' >"${TEST_TMP}/wrong-family"
    # shellcheck disable=SC2310
    if validate_generated_list_file "${TEST_TMP}/wrong-family" v6; then exit 1; fi
    printf '2001:db8::/32\n' >"${TEST_TMP}/wrong-family"
    # shellcheck disable=SC2310
    if validate_generated_list_file "${TEST_TMP}/wrong-family" v4; then exit 1; fi
)

(
    # Missing required IPv6 must be refused before the first firewall command.
    # shellcheck source=src/scripts/ip_blocker.sh
    source "${REPO_ROOT}/src/scripts/ip_blocker.sh"
    GEOBLOCK_IPV6=true
    IP_RANGE_FILE_V4="${TEST_TMP}/ranges.v4"
    IP_RANGE_FILE_V6="${TEST_TMP}/missing.v6"
    printf '192.0.2.0/24\n' >"${IP_RANGE_FILE_V4}"
    set +e
    (
        set -e
        apply_rules_nftables
    ) >"${TEST_TMP}/missing-ipv6.output" 2>&1
    status=$?
    set -e
    [[ "${status}" != 0 ]]
    grep -Fq 'Required IPv6 allowlist is empty' "${TEST_TMP}/missing-ipv6.output"
)

# Validation and application errors never trigger a global/foreign rollback.
for failure in validation application; do
    set +e
    (
        # shellcheck source=src/scripts/ip_blocker.sh
        source "${REPO_ROOT}/src/scripts/ip_blocker.sh"
        TEMP_DIR="${TEST_TMP}/${failure}"
        mkdir -p "${TEMP_DIR}"
        IP_RANGE_FILE_V4="${TEMP_DIR}/v4"
        printf '192.0.2.0/24\n' >"${IP_RANGE_FILE_V4}"
        nft() {
            printf '%s\n' "$*" >>"${TEST_TMP}/nft-${failure}"
            case "$1" in
                list) return 0 ;;
                -c) [[ "${failure}" != validation ]] ;;
                -f) return 1 ;;
                *) exit 90 ;;
            esac
        }
        apply_rules_nftables
    ) >"${TEST_TMP}/error-${failure}" 2>&1
    status=$?
    set -e
    [[ "${status}" != 0 ]]
    grep -Fq 'Existing rules were left untouched.' "${TEST_TMP}/error-${failure}"
    if [[ "${failure}" == validation ]]; then
        if grep -q '^-f ' "${TEST_TMP}/nft-${failure}"; then exit 1; fi
    fi
    if grep -Eq '(flush|destroy|delete)' "${TEST_TMP}/nft-${failure}"; then exit 1; fi
done

(
    # IPv4-only country refresh must never fetch an unused IPv6 source.
    # shellcheck source=src/scripts/geo_ip_downloader.sh
    source "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh"
    REQUIRE_IPV6_LISTS=false
    STAGING_V4="${TEST_TMP}/v4" STAGING_V6="${TEST_TMP}/v6"
    download_and_validate_simple() {
        printf '%s\n' "$1" >>"${TEST_TMP}/requested"
    }
    _download_country_ipdeny IT
    request_count="$(wc -l <"${TEST_TMP}/requested")"
    [[ "${request_count}" == 1 ]]
    ! grep -q '/ipv6/' "${TEST_TMP}/requested"
)

printf 'Firewall recovery tests passed\n'
