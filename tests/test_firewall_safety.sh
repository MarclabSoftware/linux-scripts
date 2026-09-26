#!/usr/bin/env bash

# Failure injection only: no real downloads, firewall commands or private files.
# Test doubles are called by the sourced scripts.
# shellcheck disable=SC2034,SC2154,SC2329
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIREWALL_SCRIPT="${IP_BLOCKER_TEST_SCRIPT:-${REPO_ROOT}/src/scripts/ip_blocker.sh}"
GEOIP_SCRIPT="${GEOIP_TEST_SCRIPT:-${REPO_ROOT}/src/scripts/geo_ip_downloader.sh}"
readonly REPO_ROOT FIREWALL_SCRIPT GEOIP_SCRIPT

if (($# == 0)); then
    failures=0
    for scenario in missing_interface invalid_blocklist rollback_firewall rollback_downloader interrupt_firewall interrupt_downloader downloader_policy downloader_providers manual_parser; do
        # A fresh shell keeps errexit active inside the code under test.
        if bash "${BASH_SOURCE[0]}" "${scenario}"; then
            printf 'PASS firewall safety: %s\n' "${scenario}"
        else
            printf 'FAIL firewall safety: %s\n' "${scenario}" >&2
            failures=$((failures + 1))
        fi
    done
    ((failures == 0))
    exit
fi

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export IP_BLOCKER_ENV_FILE=/nonexistent GEOIP_ENV_FILE=/nonexistent
export IP_BLOCKER_LIST_DIR="${TEST_TMP}/lists" IP_BLOCKER_COUNTRIES=IT
export IP_BLOCKER_NAT_INTERFACES=''

case "$1" in
    missing_interface)
        export IP_BLOCKER_FLOWTABLE_INTERFACES=missing-audit0
        export IP_BLOCKER_FLOWTABLE_TRUSTED_INTERFACES=missing-audit0
        # shellcheck disable=SC1090
        source "${FIREWALL_SCRIPT}"
        parse_arguments
        TEMP_DIR="${TEST_TMP}"
        IP_RANGE_FILE_V4="${TEST_TMP}/allow4"
        printf '192.0.2.0/24\n' >"${IP_RANGE_FILE_V4}"
        nft() {
            [[ "$1" != list ]] || return 1
            [[ "$1" != -f ]] || touch "${TEST_TMP}/applied"
        }
        apply_rules_nftables >"${TEST_TMP}/output" 2>&1
        [[ -f "${TEST_TMP}/applied" ]]
        ! grep -q 'flowtable f' "${TEST_TMP}/nft_ruleset.nft"
        ;;
    invalid_blocklist)
        # shellcheck disable=SC1090
        source "${FIREWALL_SCRIPT}"
        TEMP_DIR="${TEST_TMP}/stage"
        mkdir -p -- "${TEMP_DIR}" "${BLOCK_LIST_DIR}"
        source_url=https://lists.example/one
        printf '%s' "${source_url}" >"${BLOCK_LIST_FILE_NAME}"
        key="$(blocklist_cache_name_from_url "${source_url}")"
        printf '192.0.2.1\n' >"${BLOCK_LIST_DIR}/${key}"
        touch -d '2 days ago' "${BLOCK_LIST_DIR}/${key}"
        original_mtime="$(stat -c %Y "${BLOCK_LIST_DIR}/${key}")"
        curl() {
            local output='' url=''
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
                printf '  # sources\n  %s  ' "${source_url}" >"${output}"
            else
                printf 'temporarily unavailable\n' >"${output}"
            fi
        }
        # This is intentionally called in the same conditional context as main.
        # shellcheck disable=SC2310
        if download_blocklists >"${TEST_TMP}/output" 2>&1; then
            grep -qxF '192.0.2.1' "${BLOCK_LIST_DIR}/${key}"
            cached_mtime="$(stat -c %Y "${BLOCK_LIST_DIR}/${key}")"
            [[ "${cached_mtime}" == "${original_mtime}" ]]
            grep -Fq '0 fresh, 1 cached' "${TEST_TMP}/output"
        else
            exit 1
        fi
        ;;
    rollback_firewall | rollback_downloader | interrupt_firewall | interrupt_downloader)
        scenario="$1"
        script="${FIREWALL_SCRIPT}"
        [[ "${scenario}" != *_downloader ]] || script="${GEOIP_SCRIPT}"
        mkdir -p "${TEST_TMP}/active" "${TEST_TMP}/stage/new"
        printf 'last-good\n' >"${TEST_TMP}/active/list"
        set +e
        (
            # shellcheck disable=SC1090
            source "${script}"
            TEMP_DIR="${TEST_TMP}/stage"
            CLEANUP_REGISTERED=true
            trap 'exit 143' TERM
            trap cleanup EXIT
            mv() {
                local -a original_args=("$@")
                while [[ "$1" == -- || "$1" == -T ]]; do shift; done
                if [[ "${scenario}" == interrupt_* ]]; then
                    command mv "${original_args[@]}"
                    kill -TERM "${BASHPID}"
                    return
                fi
                [[ "$1" != "${TEMP_DIR}/new" && "$1" != "${TEMP_DIR}/backup" ]] || return 1
                command mv "${original_args[@]}"
            }
            atomic_swap_directory "${TEMP_DIR}/new" "${TEST_TMP}/active" "${TEMP_DIR}/backup"
        ) >"${TEST_TMP}/output" 2>&1
        status=$?
        set -e
        [[ "${status}" != 0 ]]
        grep -qxF last-good "${TEST_TMP}/stage/backup/list"
        grep -Fq "${TEST_TMP}/stage" "${TEST_TMP}/output"
        ;;
    downloader_policy)
        # Real downloader entrypoint, synthetic HTTP responses only. No private env.
        for phase in fresh cached missing; do
            set +e
            (
                export GEOIP_MAX_DOWNLOAD_RETRIES=1
                export GEOIP_ALLOW_ROOT_DIR="${TEST_TMP}/wrong"
                export GEOIP_REQUIRE_IPV6=true
                # shellcheck disable=SC1090
                source "${GEOIP_SCRIPT}"
                curl() {
                    local output=''
                    printf '%s\n' "$*" >>"${TEST_TMP}/requests"
                    [[ "${phase}" == fresh ]] || return 22
                    while (($#)); do
                        if [[ "$1" == -o ]]; then
                            output="$2"
                            shift
                        fi
                        shift
                    done
                    printf '192.0.2.0/24\n' >"${output}"
                }
                countries=ipdeny:IT
                [[ "${phase}" != missing ]] || countries=ipdeny:DE
                main -c "${countries}" -6 false -o "${TEST_TMP}/output"
            ) >"${TEST_TMP}/phase-${phase}.log" 2>&1
            status=$?
            set -e
            if [[ "${phase}" == missing ]]; then
                [[ "${status}" != 0 ]]
            else
                [[ "${status}" == 0 ]] || {
                    cat "${TEST_TMP}/phase-${phase}.log" >&2
                    exit 1
                }
            fi
            cached_file="${TEST_TMP}/output/v4/it.ipdeny.list.v4"
            grep -qxF '192.0.2.0/24' "${cached_file}"
            if [[ "${phase}" == fresh ]]; then
                touch -d '2 days ago' "${cached_file}"
                original_mtime="$(stat -c %Y "${cached_file}")"
            else
                cached_mtime="$(stat -c %Y "${cached_file}")"
                [[ "${cached_mtime}" == "${original_mtime}" ]]
            fi
        done
        [[ ! -e "${TEST_TMP}/wrong" ]]
        [[ ! -e "${TEST_TMP}/output/v4/de.ipdeny.list.v4" ]]
        grep -Fq '0 fresh, 1 cached' "${TEST_TMP}/phase-cached.log"
        if grep -Fq '/ipv6/' "${TEST_TMP}/requests"; then exit 1; fi
        ;;
    downloader_providers)
        printf 'ripencc|IT|ipv4|192.0.2.0|256|20260101|allocated\nripencc|IT|ipv6|2001:db8::|32|20260101|allocated\n' >"${TEST_TMP}/ripe"
        for provider_family in ripe:false ripe:true nirsoft:false; do
            (
                # shellcheck disable=SC1090
                source "${GEOIP_SCRIPT}"
                curl() {
                    local output='' url=''
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
                    case "${url}" in
                        *.md5)
                            checksum="$(md5sum "${TEST_TMP}/ripe")"
                            printf 'MD5 = %s\n' "${checksum%% *}" >"${output}"
                            ;;
                        */delegated-ripencc-latest) cp "${TEST_TMP}/ripe" "${output}" ;;
                        */it.csv) printf '192.0.2.0,192.0.2.255,a,b,c\n' >"${output}" ;;
                        *) return 99 ;;
                    esac
                }
                main -c "${provider_family%:*}:IT" -6 "${provider_family#*:}" -o "${TEST_TMP}/${provider_family}"
            ) >"${TEST_TMP}/${provider_family}.log" 2>&1
            if [[ "${provider_family%:*}" == ripe ]]; then
                grep -qxF '192.0.2.0 - 192.0.2.255' "${TEST_TMP}/${provider_family}/v4/it.ripe.list.v4"
            else
                grep -qxF '192.0.2.0 - 192.0.2.255' "${TEST_TMP}/${provider_family}/v4/it.nirsoft.list.v4"
            fi
            if [[ "${provider_family#*:}" == true ]]; then
                grep -qxF '2001:db8::/32' "${TEST_TMP}/${provider_family}/v6/it.ripe.list.v6"
            else
                [[ ! -e "${TEST_TMP}/${provider_family}/v6/it.${provider_family%:*}.list.v6" ]]
            fi
        done
        ;;
    manual_parser)
        # Partial parser output cannot replace a cached remote allow source.
        # shellcheck disable=SC1090
        source "${FIREWALL_SCRIPT}"
        TEMP_DIR="${TEST_TMP}/stage"
        mkdir -p "${TEMP_DIR}" "${MANUAL_ALLOW_ROOT_DIR}" "${ALLOW_SOURCE_DIR_V4}"
        url=https://lists.example/allow
        key="$(blocklist_cache_name_from_url "${url}")"
        printf '%s' "${url}" >"${MANUAL_ALLOW_SOURCES_FILE}"
        printf '192.0.2.1\n' >"${ALLOW_SOURCE_DIR_V4}/${key}.v4"
        curl() {
            while [[ "$1" != -o ]]; do shift; done
            printf '198.51.100.1\n' >"$2"
        }
        split_ip_families_from_file() {
            printf '198.51.100.1\n' >"$2"
            return 23
        }
        download_manual_allow_sources >"${TEST_TMP}/manual.log" 2>&1
        grep -qxF '192.0.2.1' "${ALLOW_SOURCE_DIR_V4}/${key}.v4"
        # Disabling IPv6 also suppresses unused manual-domain AAAA lookups.
        printf 'dual.example BOTH\nv6.example AAAA\n' >"${TEST_TMP}/domains"
        resolve_domain_family_to_file() {
            [[ "$2" == A ]] || exit 99
            printf '192.0.2.1\n' >"$3"
        }
        refresh_manual_domain_cache allow "${TEST_TMP}/domains" "${TEST_TMP}/domains4" "${TEST_TMP}/domains6"
        grep -qxF '192.0.2.1' "${TEST_TMP}/domains4/dual.example.v4"
        [[ ! -e "${TEST_TMP}/domains6/v6.example.v6" ]]
        ;;
    *) exit 2 ;;
esac
