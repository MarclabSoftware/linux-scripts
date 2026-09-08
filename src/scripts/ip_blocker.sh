#!/usr/bin/env bash

# GeoIP admission filter for native nftables; see README.md for policy and migration.
# Owns only its inet table. It does not open ports, create NAT rules, or alter
# Docker/Fail2ban tables. Existing host/forward filters still apply.
#
# Policy: ((country networks - remote blocks) + manual allows) - manual blocks.
# Established/related traffic, private sources, trusted local/WG interfaces and
# ICMPv6 bypass GeoIP. SSH new-connection meters apply only to untrusted sources.
# Downloads use validated per-source caches; an unusable required input leaves
# the live rules untouched. Only the checked nft batch is atomic, not cache I/O.
# Flow offload is opt-in and excludes DNAT; new interfaces use the normal path.
#
# Run --help for options or --check-config for a non-mutating configuration check.
set -Eeuo pipefail

###################
# Global Constants
###################

# Get the script's absolute directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
declare -r SCRIPT_DIR

# Load host-specific policy before defining immutable runtime settings.
load_environment() {
    local env_file="${IP_BLOCKER_ENV_FILE:-${SCRIPT_DIR}/ip_blocker.env}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] || {
        printf 'ip_blocker: environment file is not readable: %s\n' "${env_file}" >&2
        exit 1
    }
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) || {
        printf 'ip_blocker: environment file must not be group/world writable: %s\n' "${env_file}" >&2
        exit 1
    }

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

load_environment

# Default policy. CLI arguments override these values.
declare -r DEFAULT_COUNTRIES="${IP_BLOCKER_COUNTRIES:-}"
# Path to the downloader script
declare -r COUNTRY_IPS_DOWNLOADER="${SCRIPT_DIR}/geo_ip_downloader.sh"
# Directory structure
declare -r IP_LIST_DIR="${IP_BLOCKER_LIST_DIR:-${SCRIPT_DIR}/lists}"
declare -r GENERATED_ALLOW_ROOT_DIR="${IP_LIST_DIR}/allow/generated"
declare -r ALLOW_LIST_DIR_V4="${GENERATED_ALLOW_ROOT_DIR}/v4"
declare -r ALLOW_LIST_DIR_V6="${GENERATED_ALLOW_ROOT_DIR}/v6"
declare -r ALLOW_SOURCE_ROOT_DIR="${IP_LIST_DIR}/allow/sources"
declare -r ALLOW_SOURCE_DIR_V4="${ALLOW_SOURCE_ROOT_DIR}/v4"
declare -r ALLOW_SOURCE_DIR_V6="${ALLOW_SOURCE_ROOT_DIR}/v6"
declare -r ALLOW_DOMAIN_ROOT_DIR="${IP_LIST_DIR}/allow/domains"
declare -r ALLOW_DOMAIN_DIR_V4="${ALLOW_DOMAIN_ROOT_DIR}/v4"
declare -r ALLOW_DOMAIN_DIR_V6="${ALLOW_DOMAIN_ROOT_DIR}/v6"
declare -r MANUAL_ALLOW_ROOT_DIR="${IP_LIST_DIR}/allow/manual"
declare -r MANUAL_ALLOW_LIST_DIR_V4="${MANUAL_ALLOW_ROOT_DIR}/v4"
declare -r MANUAL_ALLOW_LIST_DIR_V6="${MANUAL_ALLOW_ROOT_DIR}/v6"
declare -r MANUAL_ALLOW_SOURCES_FILE="${MANUAL_ALLOW_ROOT_DIR}/sources.txt"
declare -r MANUAL_ALLOW_DOMAINS_FILE="${MANUAL_ALLOW_ROOT_DIR}/domains.txt"
declare -r LEGACY_MANUAL_ALLOW_SOURCES_FILE="${IP_LIST_DIR}/manual_allowlist.txt"
declare -r LEGACY_MANUAL_ALLOW_LIST_V4="${IP_LIST_DIR}/manual.v4"
declare -r LEGACY_MANUAL_ALLOW_LIST_V6="${IP_LIST_DIR}/manual.v6"
declare -r BLOCK_SOURCE_ROOT_DIR="${IP_LIST_DIR}/block/sources"
declare -r BLOCK_LIST_DIR="${BLOCK_SOURCE_ROOT_DIR}/raw"
declare -r BLOCK_LIST_DIR_V4="${BLOCK_SOURCE_ROOT_DIR}/v4"
declare -r BLOCK_LIST_DIR_V6="${BLOCK_SOURCE_ROOT_DIR}/v6"
declare -r BLOCK_DOMAIN_ROOT_DIR="${IP_LIST_DIR}/block/domains"
declare -r BLOCK_DOMAIN_DIR_V4="${BLOCK_DOMAIN_ROOT_DIR}/v4"
declare -r BLOCK_DOMAIN_DIR_V6="${BLOCK_DOMAIN_ROOT_DIR}/v6"
declare -r MANUAL_BLOCK_ROOT_DIR="${IP_LIST_DIR}/block/manual"
declare -r MANUAL_BLOCK_LIST_DIR_V4="${MANUAL_BLOCK_ROOT_DIR}/v4"
declare -r MANUAL_BLOCK_LIST_DIR_V6="${MANUAL_BLOCK_ROOT_DIR}/v6"
declare -r MANUAL_BLOCK_DOMAINS_FILE="${MANUAL_BLOCK_ROOT_DIR}/domains.txt"
# URL for the v4 blocklist index
declare -r BLOCK_LIST_URL="https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/filter.list"
declare -r BLOCK_LIST_FILE_NAME="${BLOCK_SOURCE_ROOT_DIR}/index.txt"
declare -r MANUAL_BLOCK_SOURCES_FILE="${MANUAL_BLOCK_ROOT_DIR}/sources.txt"
declare -r LEGACY_MANUAL_BLOCK_SOURCES_FILE="${IP_LIST_DIR}/manual_blocklist.txt"
# Firewall object names are configurable to support parallel/migrated policies.
declare -r NFT_TABLE_NAME="${IP_BLOCKER_NFT_TABLE_NAME:-ip_blocker}"
# Names scoped to our nftables table
declare -r ALLOW_LIST_NAME_V4="allowlist_v4"
declare -r ALLOW_LIST_NAME_V6="allowlist_v6"
# Geo-IP Provider settings
# Default provider if -p is not used
declare -r DEFAULT_PROVIDER="${IP_BLOCKER_PROVIDER:-ipdeny}"
declare -ra ALLOWED_PROVIDERS=(ipdeny ripe nirsoft)
# Stable directory containing the flock file; never unlink a live lock inode.
declare -r LOCK_DIR="${IP_BLOCKER_LOCK_DIR:-/run/ip_blocker.lock}"
# RFC 1918 private IPv4 ranges plus the unspecified address used by DHCP/BOOTP
# clients before configuration.
declare -ra PRIVATE_NETS_V4=("0.0.0.0/32" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
# Link-local and ULA sources bypass GeoIP; multicast is not a valid source.
declare -ra PRIVATE_NETS_V6=("fe80::/10" "fc00::/7")
###################
# Global Variables
###################

# These variables are set by parse_arguments()
declare ALLOWED_COUNTRIES="${DEFAULT_COUNTRIES}"
declare USE_BLOCKLIST="${IP_BLOCKER_USE_BLOCKLIST:-false}"
declare SSH_PORT="${IP_BLOCKER_SSH_PORT:-22}"
declare GEOBLOCK_IPV6="${IP_BLOCKER_GEOBLOCK_IPV6:-false}"
declare GEO_IP_PROVIDER="${DEFAULT_PROVIDER}"
declare FLOWTABLE_INTERFACES="${IP_BLOCKER_FLOWTABLE_INTERFACES:-}"
# The original direction must enter through one of these interfaces. Empty
# means no offload, even if devices were selected with the legacy -i option.
declare -r FLOWTABLE_TRUSTED_INTERFACES="${IP_BLOCKER_FLOWTABLE_TRUSTED_INTERFACES:-}"
declare CHECK_CONFIG=false

# Secure temp directory
declare TEMP_DIR=""
# Final optimized IP list files (path is set in setup_temp_dir_and_traps)
declare IP_RANGE_FILE_V4=""
declare IP_RANGE_FILE_V6=""

declare CLEANUP_REGISTERED=false
declare PRESERVE_TEMP_DIR=false
declare -ra REQUIRED_COMMANDS=(nft curl iprange awk paste stat cksum wc)
declare URL_PARSE_HOST=""
declare URL_PARSE_PORT=""

# Persistent parsed blocklists
declare BLOCK_LIST_CLEAN_V4_DIR="${BLOCK_LIST_DIR_V4}"
declare BLOCK_LIST_CLEAN_V6_DIR="${BLOCK_LIST_DIR_V6}"
# Cache for resolved hostnames to avoid redundant 'dig' calls
declare -A RESOLVED_HOSTS_CACHE

###################
# Error Handling & Logging
###################
#
# NOTE (DRY): handle_error, log, die, and _resolve_hostname are intentionally
# duplicated from geo_ip_downloader.sh. Per the project architecture, scripts are
# fully standalone with no shared library. Any changes here must be mirrored
# in geo_ip_downloader.sh and vice versa.
#

# Generic error handler, triggered by 'trap ... ERR'.
# @param $1 The line number where the error occurred (passed as $LINENO from the trap).
handle_error() {
    local exit_code=$?
    local line_number=$1
    local i stack_trace=""
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
        stack_trace+="${FUNCNAME[${i}]}(L${BASH_LINENO[$((i - 1))]})"
        ((i < ${#FUNCNAME[@]} - 1)) && stack_trace+=" → "
    done
    log "ERROR" "Script failed at line ${line_number} with exit code ${exit_code} | stack: ${stack_trace}"
    exit "${exit_code}"
}

# Logs the current DNS configuration for early-boot stability.
log_dns_config() {
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        log "INFO" "Custom DNS resolution active (Servers: ${DNS_SERVERS})"
    else
        log "INFO" "Custom DNS resolution disabled (using system resolver)"
    fi
}

# Internal helper to resolve a hostname via specific DNS servers provided in DNS_SERVERS.
# It uses an associative array to cache results for the current execution.
# @param $1 Hostname
# @param $2 Optional output variable; avoids a subshell and retains the cache.
_resolve_hostname() {
    local host="$1" result_var="${2:-}" answer=""
    local -a ips=() servers=() resolved=() rrtypes=(A AAAA)
    local ip rrtype ns

    if [[ -n "${DNS_SERVERS:-}" ]]; then
        answer="${RESOLVED_HOSTS_CACHE[${host}]:-}"
        if [[ -z "${answer}" ]]; then
            read -ra servers <<<"${DNS_SERVERS}"
            for ns in "${servers[@]}"; do
                for rrtype in "${rrtypes[@]}"; do
                    mapfile -t resolved < <(dig +short +time=2 +tries=1 "@${ns}" "${host}" "${rrtype}" 2>/dev/null || true)
                    for ip in "${resolved[@]}"; do
                        if [[ "${rrtype}" == A ]]; then
                            [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
                        else
                            [[ "${ip}" == *:* && "${ip}" =~ ^[[:xdigit:].:]+$ ]] || continue
                        fi
                        ips+=("${ip}")
                    done
                done
                ((${#ips[@]} == 0)) || break
            done
            answer="${ips[*]}"
            # Do not cache a failed lookup; a later source may retry DNS.
            [[ -z "${answer}" ]] || RESOLVED_HOSTS_CACHE[${host}]="${answer}"
        fi
    fi
    if [[ -n "${result_var}" ]]; then
        printf -v "${result_var}" '%s' "${answer}"
    else
        printf '%s\n' "${answer}"
    fi
}

# Parses an HTTP(S) URL into host and port using shell parameter expansion only.
parse_url_endpoint() {
    local url="$1"
    local endpoint default_port

    endpoint="${url#*://}"
    endpoint="${endpoint%%/*}"
    endpoint="${endpoint%%\?*}"
    endpoint="${endpoint%%#*}"
    endpoint="${endpoint##*@}"
    default_port=80
    [[ "${url}" == https://* ]] && default_port=443

    URL_PARSE_HOST="${endpoint}"
    URL_PARSE_PORT="${default_port}"

    if [[ "${endpoint}" == \[*\]* ]]; then
        URL_PARSE_HOST="${endpoint#\[}"
        URL_PARSE_HOST="${URL_PARSE_HOST%%]*}"
        if [[ "${endpoint}" == *]:* ]]; then
            URL_PARSE_PORT="${endpoint##*:}"
        fi
        return 0
    fi

    if [[ "${endpoint}" == *:* ]]; then
        URL_PARSE_HOST="${endpoint%%:*}"
        URL_PARSE_PORT="${endpoint##*:}"
    fi
}

# Builds curl --resolve options for DNS_SERVERS override with minimal process overhead.
build_resolve_options_for_url() {
    local url="$1"
    local result_var="$2"
    local addresses=""
    local -a options=()
    local -a ips=()
    local ip
    local resolve_ip
    local resolved_ips

    [[ -n "${DNS_SERVERS:-}" ]] || {
        printf -v "${result_var}" '%s' ""
        return 0
    }

    parse_url_endpoint "${url}"
    _resolve_hostname "${URL_PARSE_HOST}" resolved_ips
    read -ra ips <<<"${resolved_ips}"
    for ip in "${ips[@]}"; do
        resolve_ip="${ip}"
        [[ "${resolve_ip}" == *:* ]] && resolve_ip="[${resolve_ip}]"
        addresses+="${addresses:+,}${resolve_ip}"
    done
    # Repeated host:port entries replace each other in curl; one entry retains fallback.
    [[ -z "${addresses}" ]] || options=("--resolve" "${URL_PARSE_HOST}:${URL_PARSE_PORT}:${addresses}")

    printf -v "${result_var}" '%s' "${options[*]-}"
}

# Cheap HTML/XML detector without spawning head/grep for every file.
file_has_markup_header() {
    local file="$1"
    local line
    local checked=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        ((checked < 50)) || break
        line="${line,,}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        checked=$((checked + 1))
        if [[ "${line}" == *'<!doctype'* || "${line}" == *'<?xml'* || "${line}" == *'<!--'* || "${line}" == *'<html'* || "${line}" == *'<head'* || "${line}" == *'<body'* ]]; then
            return 0
        fi
    done <"${file}"

    return 1
}

# Waits until the shell has fewer than the requested number of running jobs.
wait_for_job_slot_limit() {
    local max_jobs="$1"
    local -a running_jobs=()

    while :; do
        mapfile -t running_jobs < <(jobs -pr || true)
        ((${#running_jobs[@]} < max_jobs)) && return 0
        wait -n || true
    done
}

# Setup signal traps for robust execution and cleanup
setup_signal_handlers() {
    # Handle SIGINT (Ctrl+C)
    trap 'log "INFO" "Received SIGINT"; exit 130' INT
    # Handle SIGTERM (kill)
    trap 'log "INFO" "Received SIGTERM"; exit 143' TERM
    # Handle ERR (any command failure)
    trap 'handle_error $LINENO' ERR
    # Handle EXIT (any script exit)
    trap 'cleanup' EXIT
    # Flag to prevent double cleanup
    CLEANUP_REGISTERED=true
}

# Standardized logging function
log() {
    # Uses printf builtin %()T for timestamp (no subshell, no external process)
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] [PID:%d] %s\n' -1 "$1" "${BASHPID:-$$}" "$2" >&2
}

# Log an error and exit
die() {
    log "ERROR" "$*"
    exit 1
}

# Cleanup secure temporary directory on script exit
cleanup() {
    if [[ "${CLEANUP_REGISTERED}" == true && -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        if [[ "${PRESERVE_TEMP_DIR}" == true ]]; then
            log "ERROR" "Recovery files retained at ${TEMP_DIR}; inspect them before the next run."
        else
            rm -rf -- "${TEMP_DIR}"
        fi
    fi
    # The kernel releases descriptor 9 on exit, including after SIGKILL.
}

# Check for root, create secure temp dir, and setup traps
setup_temp_dir_and_traps() {
    # 1. Check root
    [[ "${EUID}" -ne 0 ]] && die "Please run as root/sudo"

    # 2. Acquire the kernel lock before creating mutable working state.
    command -v flock >/dev/null || die "Required command not found: flock"
    mkdir -p -- "${LOCK_DIR}" || die "Failed to prepare lock directory"
    exec 9>"${LOCK_DIR}/lock" || die "Failed to open lock file"
    flock -n 9 || die "Script is already running. Aborting."
    # Refuse overlap with an older script that still uses a PID lock.
    local lock_pid=""
    if [[ -f "${LOCK_DIR}/pid" ]]; then
        read -r lock_pid <"${LOCK_DIR}/pid" || true
        if [[ "${lock_pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            die "An older script is still running (PID: ${lock_pid}). Aborting."
        fi
    fi
    setup_signal_handlers

    # 3. Create secure temp directory under the persistent list root.
    # Staging beside the cache keeps renames on the same filesystem.
    mkdir -p "${IP_LIST_DIR}" || die "Failed to prepare list root directory"
    TEMP_DIR=$(mktemp -d "${IP_LIST_DIR}/.ipblocker.XXXXXX") || die "Failed to create secure temp directory"

    # 4. Set global paths for our temp files
    IP_RANGE_FILE_V4="${TEMP_DIR}/${ALLOW_LIST_NAME_V4}.iprange.txt"
    IP_RANGE_FILE_V6="${TEMP_DIR}/${ALLOW_LIST_NAME_V6}.iprange.txt"

}

###################
# Argument Parsing
###################

# Display usage information. Accepts an optional exit code (default: 1).
# Pass 0 when invoked via -h; pass 1 (default) for invalid-option paths.
print_usage() {
    local exit_code="${1:-1}"
    cat <<EOF

Usage: $0 [-c countries] [-p provider] [-b] [-G] [-s sshPort] [-i interfaces] [-C] [-h]

Options:
    -c countries   Specify allowed countries
                   Simple: "IT,DE,FR" (uses provider from -p).
                   Advanced: "ripe:IT,FR;ipdeny:CN;nirsoft:KR,IT" (ignores -p).
    -p provider    Geo-IP provider: 'ipdeny', 'ripe', 'nirsoft' (default: ${DEFAULT_PROVIDER})
    -b             Enable block lists (Applies to IPv4; IPv6 if -G also set)
    -G             Enable Geo-blocking for IPv6 (default: false; needed for v6 blocks)
    -s sshPort     Specify SSH port (default: 22)
    -i interfaces  Interfaces for Flowtable offload (e.g. "eth0 wg0 br-*")
    -C             Validate configuration without changing the firewall
    -h, --help     Display this help message
EOF
    exit "${exit_code}"
}

# Parse command line arguments using getopts
parse_arguments() {
    [[ "${1:-}" != --help ]] || print_usage 0
    [[ "${1:-}" != --check-config ]] || set -- -C "${@:2}"
    if [[ $# -eq 0 ]]; then
        log "INFO" "No CLI arguments provided; using environment configuration."
    fi
    local opt OPTARG OPTIND=1
    # Silent mode (optstring starts with ':'): unknown opts land in '?' case,
    # missing args land in ':' case — OPTERR is ignored.
    while getopts ":c:p:bs:i:hGC" opt; do
        case ${opt} in
            c) ALLOWED_COUNTRIES="${OPTARG}" ;;
            p) GEO_IP_PROVIDER="${OPTARG}" ;;
            b) USE_BLOCKLIST=true ;;
            G) GEOBLOCK_IPV6=true ;;
            s) SSH_PORT="${OPTARG}" ;;
            i) FLOWTABLE_INTERFACES="${OPTARG}" ;;
            C) CHECK_CONFIG=true ;;
            h) print_usage 0 ;;
            \?)
                log "ERROR" "Invalid option: -${OPTARG}"
                print_usage
                ;;
            :)
                log "ERROR" "The option -${OPTARG} requires an argument"
                print_usage
                ;;
            *)
                log "ERROR" "Unexpected option parser state"
                print_usage
                ;;
        esac
    done
    shift "$((OPTIND - 1))"
    (($# == 0)) || die "unexpected positional arguments; see --help"

    case "${USE_BLOCKLIST}" in
        1 | true) USE_BLOCKLIST=true ;;
        0 | false) USE_BLOCKLIST=false ;;
        *) die "IP_BLOCKER_USE_BLOCKLIST must be 0, 1, true or false" ;;
    esac
    case "${GEOBLOCK_IPV6}" in
        1 | true) GEOBLOCK_IPV6=true ;;
        0 | false) GEOBLOCK_IPV6=false ;;
        *) die "IP_BLOCKER_GEOBLOCK_IPV6 must be 0, 1, true or false" ;;
    esac

    [[ "${IP_LIST_DIR}" == /* && "${LOCK_DIR}" == /* ]] ||
        die "list and lock directories must be absolute paths"
    [[ "${NFT_TABLE_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
        die "IP_BLOCKER_NFT_TABLE_NAME is not a valid nftables identifier"
    [[ -z "${IP_BLOCKER_NAT_INTERFACES:-}" ]] ||
        die "IP_BLOCKER_NAT_INTERFACES is retired. Move scoped VPN NAT to its own nftables config, then remove this setting."

    # These values enter nft syntax: accept interface names and a
    # single trailing wildcard, never arbitrary rules or shell expansion.
    local pattern
    local -a interface_patterns=()
    IFS=' ' read -r -a interface_patterns <<<"${FLOWTABLE_INTERFACES} ${FLOWTABLE_TRUSTED_INTERFACES}"
    for pattern in "${interface_patterns[@]}"; do
        [[ "${pattern}" =~ ^[a-zA-Z0-9_.:-]+\*?$ && ${#pattern} -le 16 ]] ||
            die "Invalid interface pattern: ${pattern}"
    done

    [[ "${SSH_PORT}" =~ ^[0-9]{1,5}$ ]] ||
        die "SSH port must be a number between 1 and 65535"
    SSH_PORT=$((10#${SSH_PORT}))
    ((SSH_PORT >= 1 && SSH_PORT <= 65535)) ||
        die "SSH port must be a number between 1 and 65535"
    # Normalize: strip any trailing separators the user may have left (e.g. "ipdeny:IT;")
    ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES//[[:space:]]/}"
    ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES%%;}"
    ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES%%,}"

    # Validate country codes and every provider in advanced syntax.
    if [[ "${ALLOWED_COUNTRIES}" == *":"* ]]; then
        # Advanced syntax (e.g., "ripe:IT,FR;ipdeny:CN")
        local adv_regex='^[A-Za-z]+:[A-Za-z]{2}(,[A-Za-z]{2})*(;[A-Za-z]+:[A-Za-z]{2}(,[A-Za-z]{2})*)*$'
        if [[ ! "${ALLOWED_COUNTRIES}" =~ ${adv_regex} ]]; then
            die "Invalid advanced country syntax. Use format like 'provider:C1,C2;provider2:C3'"
        fi

        local group provider
        local -a provider_groups
        IFS=';' read -r -a provider_groups <<<"${ALLOWED_COUNTRIES}"
        for group in "${provider_groups[@]}"; do
            provider="${group%%:*}"
            provider="${provider,,}"
            [[ " ${ALLOWED_PROVIDERS[*]} " == *" ${provider} "* ]] ||
                die "Invalid provider '${provider}'. Allowed: ${ALLOWED_PROVIDERS[*]}"
            [[ "${provider}" != nirsoft || "${GEOBLOCK_IPV6}" == false ]] ||
                die "Provider 'nirsoft' is IPv4-only; disable IPv6 filtering or select another provider."
        done
    else
        # Simple syntax (e.g., "IT,FR,DE")
        if [[ ! "${ALLOWED_COUNTRIES}" =~ ^[A-Za-z]{2}(,[A-Za-z]{2})*$ ]]; then
            die "Country codes must be 2-letter ISO codes, comma-separated (e.g., IT,FR,DE)"
        fi

        [[ " ${ALLOWED_PROVIDERS[*]} " == *" ${GEO_IP_PROVIDER} "* ]] ||
            die "Invalid provider '${GEO_IP_PROVIDER}'. Allowed: ${ALLOWED_PROVIDERS[*]}"
        [[ "${GEO_IP_PROVIDER}" != nirsoft || "${GEOBLOCK_IPV6}" == false ]] ||
            die "Provider 'nirsoft' is IPv4-only; disable IPv6 filtering or select another provider."
        log "INFO" "Using Geo-IP provider: ${GEO_IP_PROVIDER}"
    fi
}

###################
# System & Network Checks
###################

check_installed_commands() {
    local missing_commands=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing_commands+=("${cmd}")
    done
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands: ${missing_commands[*]}"

    # dig is required only when DNS_SERVERS is set (early-boot DNS override)
    if [[ -n "${DNS_SERVERS:-}" ]] && ! command -v dig >/dev/null 2>&1; then
        die "DNS_SERVERS is set but 'dig' (bind-tools/dnsutils) is not installed."
    fi

    # IP Range Runtime Version/Feature Check (Requires iprange >= 2.0.0)
    local -a missing_features=()
    iprange --has-ipv6 >/dev/null 2>&1 || missing_features+=("ipv6")
    iprange --has-directory-loading >/dev/null 2>&1 || missing_features+=("directory-loading")
    iprange --has-filelist-loading >/dev/null 2>&1 || missing_features+=("filelist-loading")

    if [[ ${#missing_features[@]} -gt 0 ]]; then
        die "iprange 2.0.0 or newer is required. Missing features: ${missing_features[*]}"
    fi
}

# The readable URL prefix plus checksum gives a stable per-source cache key.
blocklist_cache_name_from_url() {
    local url="$1"
    local scheme="${url%%:*}"
    local normalized="${url#*://}"
    local checksum=""
    local cksum_output=""

    normalized="${normalized##*@}"
    normalized="${normalized%%#*}"
    normalized="${normalized//[^A-Za-z0-9._-]/_}"
    while [[ "${normalized}" == *"__"* ]]; do
        normalized="${normalized//__/_}"
    done
    normalized="${normalized##_}"
    normalized="${normalized%%_}"

    if ((${#normalized} > 220)); then
        normalized="${normalized:0:140}_${normalized: -60}"
    fi

    if ! cksum_output=$(printf '%s' "${url}" | cksum); then
        die "Failed to derive stable cache key for blocklist URL: ${url}"
    fi
    checksum="${cksum_output%% *}"

    printf '%s\n' "${scheme}_${normalized:-list}_${checksum}"
}

# This function is a predicate and explicitly returns validation status.
cached_blocklist_file_is_valid() {
    [[ -s "$1" ]] || return 1
    # Validate content, not just HTTP success. Reuse the actual address parser.
    # shellcheck disable=SC2310
    split_ip_families_from_file "$1" /dev/null /dev/null
}

# A remote index must contain at least one complete HTTP(S) source URL.
blocklist_index_is_valid() {
    [[ -s "$1" ]] || return 1
    awk '
        { sub(/\r$/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 ~ /^(#|$)/) next }
        /^https?:\/\/[^[:space:]]+$/ { found = 1; next }
        { invalid = 1 }
        END { exit (!found || invalid) }
    ' "$1"
}

# Activates staged data with rollback; recovery copies survive failed rollback.
atomic_swap_directory() {
    local new_dir="$1" target_dir="$2" backup_dir="$3"
    local parent_dir="${target_dir%/*}"

    [[ -d "${new_dir}" ]] || die "Staging directory not found: ${new_dir}"
    [[ ! -e "${backup_dir}" ]] || die "Recovery directory already exists: ${backup_dir}"
    [[ "${parent_dir}" == "${target_dir}" ]] || mkdir -p -- "${parent_dir}"

    # Two renames, not an atomic exchange. Retain recovery data if interrupted
    # after moving the old directory, including when rollback itself fails.
    if [[ -d "${target_dir}" ]]; then
        PRESERVE_TEMP_DIR=true
        mv -T -- "${target_dir}" "${backup_dir}" || die "Failed to back up ${target_dir}"
    fi
    if mv -T -- "${new_dir}" "${target_dir}"; then
        PRESERVE_TEMP_DIR=false
        rm -rf -- "${backup_dir}"
        return 0
    fi

    log "ERROR" "Failed to activate ${target_dir}; attempting rollback."
    if [[ -d "${backup_dir}" ]]; then
        if mv -T -- "${backup_dir}" "${target_dir}"; then
            PRESERVE_TEMP_DIR=false
        else
            log "ERROR" "Rollback failed; old data remains at ${backup_dir}"
        fi
    fi
    die "Directory activation failed for ${target_dir}"
}

# Helper to expand interface wildcards (e.g. "eth0 br-*")
expand_interfaces() {
    local input_patterns="$1"
    local include_bridge_ports="${2:-false}"
    local -a patterns=()
    local -a expanded_list=()
    local -a unique_list=()
    local match
    local iface
    local joined=""
    declare -A seen_ifaces=()

    IFS=' ' read -r -a patterns <<<"${input_patterns}"
    local pattern
    for pattern in "${patterns[@]}"; do
        if [[ "${pattern}" == *"*"* ]]; then
            # Expand /sys/class/net using compgen to avoid word splitting.
            # We append '|| true' because if no matches are found, compgen returns 1,
            # which triggers the ERR trap in the subshell due to 'set -E'.
            local matches=()
            mapfile -t matches < <(compgen -G "/sys/class/net/${pattern}" 2>/dev/null || true)

            for match in "${matches[@]}"; do
                expanded_list+=("${match##*/}")
            done
        else
            # Literal interface
            if [[ -d "/sys/class/net/${pattern}" ]]; then
                expanded_list+=("${pattern}")
            else
                log "WARN" "Interface '${pattern}' not found, skipping."
            fi
        fi
    done

    if [[ "${include_bridge_ports}" == true ]]; then
        # Fastpath bridge traversal needs the actual ports, not only br-*.
        # ponytail: snapshot at each firewall run; newly created ports use the
        # classic path until the next run, without a separate Docker watcher.
        for iface in "${expanded_list[@]}"; do
            for match in /sys/class/net/"${iface}"/brif/*; do
                [[ -e "${match}" ]] || continue
                expanded_list+=("${match##*/}")
            done
        done
    fi

    # Deduplicate while preserving discovery order, then join with commas.
    for iface in "${expanded_list[@]}"; do
        [[ -n "${seen_ifaces[${iface}]:-}" ]] && continue
        seen_ifaces[${iface}]=1
        unique_list+=("${iface}")
    done

    for iface in "${unique_list[@]}"; do
        joined+="${joined:+,}\"${iface}\""
    done

    [[ -z "${joined}" ]] || printf '%s\n' "${joined}"
    return 0
}

###################
# List Generation
###################

# Download and process blocklists
# Download and cache helpers return status used for fallback selection.
download_blocklists() {
    log "INFO" "Downloading blocklists..."

    # Limit parallel downloads to avoid a process burst on small machines.
    local max_jobs=8
    local urls=()
    local -a expected_files=()
    local -a missing_blocklist_files=()
    local -A scheduled_files=()
    local url cache_name

    # 1. Download and parse remote git index (v4 lists).
    # Non-fatal on network failure: fall back to the cached index from the previous
    # run (which lives at BLOCK_LIST_FILE_NAME on disk). Only return 1 if the index
    # is unreachable AND no cached copy exists.
    local -a index_resolve_opts=()
    local index_resolve_opts_str=""
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        build_resolve_options_for_url "${BLOCK_LIST_URL}" index_resolve_opts_str
        [[ -n "${index_resolve_opts_str}" ]] && read -ra index_resolve_opts <<<"${index_resolve_opts_str}"
    fi

    local staged_index="${TEMP_DIR}/blocklist-index.txt"
    # shellcheck disable=SC2310
    if curl -fsSL "${index_resolve_opts[@]}" --connect-timeout 10 --max-time 30 "${BLOCK_LIST_URL}" -o "${staged_index}" &&
        blocklist_index_is_valid "${staged_index}"; then
        mv -fT -- "${staged_index}" "${BLOCK_LIST_FILE_NAME}" || return
    else
        rm -f -- "${staged_index}" || return
        # shellcheck disable=SC2310
        if blocklist_index_is_valid "${BLOCK_LIST_FILE_NAME}"; then
            log "WARN" "Blocklist index unreachable; using cached index from previous run."
        else
            log "WARN" "Blocklist index unreachable and no cached index found. Skipping blocklists."
            return 1
        fi
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
        urls+=("${line}")
    done <"${BLOCK_LIST_FILE_NAME}"

    # 2. Parse additional manual blocklist sources (canonical path first).
    if [[ -f "${MANUAL_BLOCK_SOURCES_FILE}" ]]; then
        log "INFO" "Adding manual blocklist sources from ${MANUAL_BLOCK_SOURCES_FILE}"
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            urls+=("${line}")
        done <"${MANUAL_BLOCK_SOURCES_FILE}"
    fi

    if [[ -f "${LEGACY_MANUAL_BLOCK_SOURCES_FILE}" ]]; then
        log "WARN" "Legacy manual blocklist source file detected: ${LEGACY_MANUAL_BLOCK_SOURCES_FILE}. Prefer ${MANUAL_BLOCK_SOURCES_FILE}."
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            urls+=("${line}")
        done <"${LEGACY_MANUAL_BLOCK_SOURCES_FILE}"
    fi

    for url in "${urls[@]}"; do
        cache_name=$(blocklist_cache_name_from_url "${url}")
        if [[ -n "${scheduled_files[${cache_name}]:-}" ]]; then
            continue
        fi
        scheduled_files[${cache_name}]="${url}"
        expected_files+=("${cache_name}")
        # Populate the parent cache once; every download worker inherits it.
        parse_url_endpoint "${url}"
        _resolve_hostname "${URL_PARSE_HOST}" >/dev/null
    done

    if ((${#expected_files[@]} == 0)); then
        log "WARN" "No blocklist sources configured after parsing."
        return 1
    fi

    # 3. Download ALL Lists into a staging directory (inside TEMP_DIR).
    # Stage first, then replace BLOCK_LIST_DIR only
    # when every expected source is satisfied by either the fresh download or the
    # cached copy of that exact same list.
    log "INFO" "Dispatching ${#expected_files[@]} downloads..."
    local staging_dir="${TEMP_DIR}/bl_staging"
    mkdir -p "${staging_dir}"

    (
        cd "${staging_dir}" || die "Failed to change directory to ${staging_dir}"
        for cache_name in "${expected_files[@]}"; do
            # Throttle: wait for a slot before spawning the next job
            wait_for_job_slot_limit "${max_jobs}"
            (
                local -a resolve_opts=()
                local resolve_opts_str=""
                local curl_err
                local partial_file="${cache_name}.part"
                local url="${scheduled_files[${cache_name}]}"
                if [[ -n "${DNS_SERVERS:-}" ]]; then
                    build_resolve_options_for_url "${url}" resolve_opts_str
                    [[ -n "${resolve_opts_str}" ]] && read -ra resolve_opts <<<"${resolve_opts_str}"
                fi

                log "INFO" "Downloading: ${url}"
                # shellcheck disable=SC2310
                if ! curl_err=$(curl -fsSL "${resolve_opts[@]}" -o "${partial_file}" --connect-timeout 15 --max-time 90 "${url}" 2>&1); then
                    log "WARN" "Failed to download ${url}: ${curl_err%%$'\n'*}"
                    rm -f -- "${partial_file}"
                else
                    mv -fT -- "${partial_file}" "${cache_name}"
                fi
            ) &
        done
        wait || true
    )

    # 4. Validate results and satisfy partial failures from the exact same cached list.
    local -i total ok failed fresh=0 cached_count=0 oldest_cache=0 cache_time cache_age=0 now=0
    local staged_file cached_file
    total=${#expected_files[@]}
    ok=0

    for cache_name in "${expected_files[@]}"; do
        staged_file="${staging_dir}/${cache_name}"
        # shellcheck disable=SC2310
        if cached_blocklist_file_is_valid "${staged_file}"; then
            ok=$((ok + 1))
            fresh=$((fresh + 1))
            continue
        fi

        rm -f -- "${staged_file}"
        cached_file="${BLOCK_LIST_DIR}/${cache_name}"
        # shellcheck disable=SC2310
        if cached_blocklist_file_is_valid "${cached_file}"; then
            cp --preserve=timestamps -f -- "${cached_file}" "${staged_file}" || die "Failed to restore cached blocklist '${cache_name}'"
            log "WARN" "Using cached blocklist for unavailable source: ${cache_name}"
            ok=$((ok + 1))
            cached_count=$((cached_count + 1))
            cache_time=$(stat -c %Y -- "${cached_file}") || die "Cannot read cache age"
            if ((oldest_cache == 0 || cache_time < oldest_cache)); then
                oldest_cache=${cache_time}
            fi
            continue
        fi

        missing_blocklist_files+=("${cache_name}")
    done

    failed=$((total - ok))
    if ((${#missing_blocklist_files[@]} > 0)); then
        log "WARN" "Blocklists incomplete (${ok}/${total} ready); missing exact cache for: ${missing_blocklist_files[*]}. Previous cache retained."
        return 1
    fi

    if ((oldest_cache > 0)); then
        printf -v now '%(%s)T' -1
        cache_age=$((now - oldest_cache))
        ((cache_age >= 0)) || cache_age=0
    fi
    log "INFO" "Blocklists: ${fresh} fresh, ${cached_count} cached, ${failed} missing; oldest cache ${cache_age}s."
    atomic_swap_directory "${staging_dir}" "${BLOCK_LIST_DIR}" "${TEMP_DIR}/block_raw.backup"
    log "INFO" "Blocklist download complete."
}

# Pre-process downloaded lists to separate v4 and v6 content
# This prevents iprange from misinterpreting IPv6 addresses as DNS names
# Markup detection is intentionally used as a validation predicate.
separate_ip_families() {
    log "INFO" "Separating IPv4 and IPv6 addresses from raw blocklists..."
    local v4_clean_dir="${TEMP_DIR}/block_v4_clean"
    local v6_clean_dir="${TEMP_DIR}/block_v6_clean"
    local file filename pid failed=0
    local -a pids=()
    mkdir -p -- "${v4_clean_dir}" "${v6_clean_dir}" || die "Failed to prepare blocklist staging"

    for file in "${BLOCK_LIST_DIR}"/*; do
        [[ -f "${file}" ]] || continue
        filename="${file##*/}"
        split_ip_families_from_file "${file}" "${v4_clean_dir}/${filename}.v4" "${v6_clean_dir}/${filename}.v6" &
        pids+=("$!")
        if ((${#pids[@]} == 8)); then
            for pid in "${pids[@]}"; do
                wait "${pid}" || failed=1
            done
            pids=()
        fi
    done
    # Every parser must finish successfully before either active directory moves.
    for pid in "${pids[@]}"; do
        wait "${pid}" || failed=1
    done
    ((failed == 0)) || die "Blocklist parsing failed; previous parsed lists retained"

    atomic_swap_directory "${v4_clean_dir}" "${BLOCK_LIST_DIR_V4}" "${TEMP_DIR}/block_v4.backup"
    atomic_swap_directory "${v6_clean_dir}" "${BLOCK_LIST_DIR_V6}" "${TEMP_DIR}/block_v6.backup"
    BLOCK_LIST_CLEAN_V4_DIR="${BLOCK_LIST_DIR_V4}"
    BLOCK_LIST_CLEAN_V6_DIR="${BLOCK_LIST_DIR_V6}"
    log "INFO" "Separation complete."
}

directory_has_files() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 1
    compgen -G "${dir%/}/*" >/dev/null
}

# An empty source directory is a successful no-op.
copy_directory_contents_if_present() {
    local src_dir="$1"
    local dst_dir="$2"
    local -a files=()

    # shellcheck disable=SC2310
    directory_has_files "${src_dir}" || return 0
    files=("${src_dir}"/*)
    cp -f "${files[@]}" "${dst_dir}"/
}

# Markup detection is intentionally used as a validation predicate.
split_ip_families_from_file() {
    local input_file="$1"
    local out_v4="$2"
    local out_v6="$3"
    local want_v6=0

    [[ "${GEOBLOCK_IPV6}" == true ]] && want_v6=1

    # shellcheck disable=SC2310
    if file_has_markup_header "${input_file}"; then
        log "WARN" "File '$(basename "${input_file}")' appears to be HTML/XML (invalid content). Skipping."
        return 1
    fi

    awk -v out_v4="${out_v4}" -v out_v6="${out_v6}" -v want_v6="${want_v6}" '
        function is_valid_cidr(prefix, maxbits) {
            return (prefix ~ /^[0-9]+$/ && prefix + 0 >= 0 && prefix + 0 <= maxbits)
        }
        function is_valid_ipv4(addr, parts, count, i, host) {
            host = addr
            if (addr ~ /\//) {
                count = split(addr, parts, "/")
                if (count != 2 || !is_valid_cidr(parts[2], 32)) return 0
                host = parts[1]
            }
            count = split(host, parts, ".")
            if (count != 4) return 0
            for (i = 1; i <= 4; i++) {
                if (parts[i] !~ /^[0-9]+$/ || parts[i] + 0 > 255) return 0
            }
            return 1
        }
        function is_valid_hex_group(group) {
            return (group ~ /^[0-9A-Fa-f]+$/ && length(group) <= 4)
        }
        function validate_ipv6_sequence(seq, groups, count, i, width) {
            if (seq == "") return 0
            count = split(seq, groups, ":")
            width = 0
            for (i = 1; i <= count; i++) {
                if (groups[i] ~ /\./) {
                    if (i != count || groups[i] ~ /\// || !is_valid_ipv4(groups[i])) return -1
                    width += 2
                    continue
                }
                if (!is_valid_hex_group(groups[i])) return -1
                width++
            }
            return width
        }
        function is_valid_ipv6(addr, parts, host, tmp, halves, left_width, right_width, total_width) {
            host = addr
            if (addr ~ /\//) {
                if (split(addr, parts, "/") != 2 || !is_valid_cidr(parts[2], 128)) return 0
                host = parts[1]
            }
            if (host !~ /:/ || host ~ /:::/) return 0
            if (host == "::") return 1
            if (host ~ /^:[^:]/ || host ~ /[^:]:$/) return 0

            tmp = host
            if (gsub(/::/, "@", tmp) > 1) return 0

            if (index(host, "::")) {
                split(host, halves, /::/)
                left_width = validate_ipv6_sequence(halves[1])
                right_width = validate_ipv6_sequence(halves[2])
                if (left_width < 0 || right_width < 0) return 0
                total_width = left_width + right_width
                return (total_width < 8)
            }

            total_width = validate_ipv6_sequence(host)
            return (total_width == 8)
        }
        function ipv4_to_int(addr, octets) {
            split(addr, octets, ".")
            return (((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4])
        }
        function is_valid_ipv4_range(addr_range, parts, start_ip, end_ip) {
            if (split(addr_range, parts, /[[:space:]]*-[[:space:]]*/) != 2) return 0
            if (parts[1] ~ /\// || parts[2] ~ /\// || !is_valid_ipv4(parts[1]) || !is_valid_ipv4(parts[2])) return 0
            start_ip = ipv4_to_int(parts[1])
            end_ip = ipv4_to_int(parts[2])
            return (start_ip <= end_ip)
        }
        {
            sub(/\r$/, "", $0)
            sub(/[[:space:]]*[#;].*$/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 == "") next

            if (is_valid_ipv4($0) || is_valid_ipv4_range($0)) {
                # Keep one canonical range format for downstream iprange consumers.
                gsub(/[[:space:]]*-[[:space:]]*/, " - ", $0)
                print >> out_v4
                valid++
                next
            }

            if (is_valid_ipv6($0)) {
                if (want_v6) print >> out_v6
                valid++
            }
        }
        END { exit (valid == 0) }
    ' "${input_file}"
}

# Per-source parsing failures are handled without aborting other sources.
download_manual_allow_sources() {
    log "INFO" "Refreshing remote allowlist sources..."

    local staging_v4="${TEMP_DIR}/allow_sources_v4"
    local staging_v6="${TEMP_DIR}/allow_sources_v6"
    local -a urls=()
    local -A scheduled_files=()
    local url cache_name temp_file
    local had_cached_copy=false
    local had_any_valid_output=false

    mkdir -p "${staging_v4}" "${staging_v6}" || die "Failed to prepare allowlist source staging directories."

    if [[ -f "${MANUAL_ALLOW_SOURCES_FILE}" ]]; then
        log "INFO" "Loading remote allowlist sources from ${MANUAL_ALLOW_SOURCES_FILE}"
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            urls+=("${line}")
        done <"${MANUAL_ALLOW_SOURCES_FILE}"
    fi

    if [[ -f "${LEGACY_MANUAL_ALLOW_SOURCES_FILE}" ]]; then
        log "WARN" "Legacy manual allowlist source file detected: ${LEGACY_MANUAL_ALLOW_SOURCES_FILE}. Prefer ${MANUAL_ALLOW_SOURCES_FILE}."
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            urls+=("${line}")
        done <"${LEGACY_MANUAL_ALLOW_SOURCES_FILE}"
    fi

    if [[ ${#urls[@]} -eq 0 ]]; then
        log "INFO" "No remote allowlist sources configured."
        atomic_swap_directory "${staging_v4}" "${ALLOW_SOURCE_DIR_V4}" "${TEMP_DIR}/allow_sources_v4.backup"
        atomic_swap_directory "${staging_v6}" "${ALLOW_SOURCE_DIR_V6}" "${TEMP_DIR}/allow_sources_v6.backup"
        return 0
    fi

    for url in "${urls[@]}"; do
        cache_name=$(blocklist_cache_name_from_url "${url}")
        [[ -n "${scheduled_files[${cache_name}]:-}" ]] && continue
        scheduled_files[${cache_name}]=1

        temp_file=$(mktemp --tmpdir="${TEMP_DIR}") || die "Failed to create temp file for remote allowlist source."
        had_cached_copy=false
        had_any_valid_output=false

        local -a resolve_opts=()
        local resolve_opts_str=""
        if [[ -n "${DNS_SERVERS:-}" ]]; then
            build_resolve_options_for_url "${url}" resolve_opts_str
            [[ -n "${resolve_opts_str}" ]] && read -ra resolve_opts <<<"${resolve_opts_str}"
        fi

        if curl -fsSL "${resolve_opts[@]}" -o "${temp_file}" --connect-timeout 15 --max-time 90 "${url}" 2>/dev/null; then
            # shellcheck disable=SC2310
            if split_ip_families_from_file "${temp_file}" "${staging_v4}/${cache_name}.v4" "${staging_v6}/${cache_name}.v6"; then
                if [[ -s "${staging_v4}/${cache_name}.v4" || -s "${staging_v6}/${cache_name}.v6" ]]; then
                    had_any_valid_output=true
                else
                    log "WARN" "Remote allowlist source ${url} produced no valid IPv4/IPv6 entries."
                fi
            else
                # A parser can fail after writing output; never publish the prefix.
                rm -f -- "${staging_v4}/${cache_name}.v4" "${staging_v6}/${cache_name}.v6"
            fi
        fi

        if [[ "${had_any_valid_output}" != true ]]; then
            if [[ -f "${ALLOW_SOURCE_DIR_V4}/${cache_name}.v4" ]]; then
                cp --preserve=timestamps -f -- "${ALLOW_SOURCE_DIR_V4}/${cache_name}.v4" "${staging_v4}/${cache_name}.v4"
                had_cached_copy=true
            fi
            if [[ "${GEOBLOCK_IPV6}" == true && -f "${ALLOW_SOURCE_DIR_V6}/${cache_name}.v6" ]]; then
                cp --preserve=timestamps -f -- "${ALLOW_SOURCE_DIR_V6}/${cache_name}.v6" "${staging_v6}/${cache_name}.v6"
                had_cached_copy=true
            fi

            if [[ "${had_cached_copy}" == true ]]; then
                log "WARN" "Using cached remote allowlist source for ${url}"
            else
                log "WARN" "Skipping unavailable remote allowlist source with no cache: ${url}"
            fi
        fi

        rm -f "${temp_file}"
    done

    atomic_swap_directory "${staging_v4}" "${ALLOW_SOURCE_DIR_V4}" "${TEMP_DIR}/allow_sources_v4.backup"
    atomic_swap_directory "${staging_v6}" "${ALLOW_SOURCE_DIR_V6}" "${TEMP_DIR}/allow_sources_v6.backup"
    log "INFO" "Remote allowlist source refresh complete."
}

domain_cache_name_from_hostname() {
    local host="${1,,}"
    host="${host//[^a-z0-9._-]/_}"
    printf '%s' "${host}"
}

resolve_domain_family_to_file() {
    local domain="$1"
    local family="$2"
    local output_file="$3"
    local -a servers=()
    local -a resolved=()
    local ns
    local resolved_output

    rm -f "${output_file}"

    if [[ -n "${DNS_SERVERS:-}" ]]; then
        read -ra servers <<<"${DNS_SERVERS}"
        for ns in "${servers[@]}"; do
            if [[ "${family}" == "A" ]]; then
                if ! resolved_output=$(dig +short +time=2 +tries=1 "@${ns}" "${domain}" A 2>/dev/null |
                    awk '$1 ~ /^[0-9.]+$/ && !seen[$1]++ { print $1 }'); then
                    continue
                fi
            else
                if ! resolved_output=$(dig +short +time=2 +tries=1 "@${ns}" "${domain}" AAAA 2>/dev/null |
                    awk '$1 ~ /:/ && !seen[$1]++ { print $1 }'); then
                    continue
                fi
            fi
            resolved=()
            [[ -z "${resolved_output}" ]] || mapfile -t resolved <<<"${resolved_output}"
            if ((${#resolved[@]} > 0)); then
                printf '%s\n' "${resolved[@]}" >"${output_file}"
                return 0
            fi
        done
        return 1
    fi

    if [[ "${family}" == "A" ]]; then
        getent ahostsv4 "${domain}" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ && !seen[$1]++ { print $1 }' >"${output_file}" || true
    else
        getent ahostsv6 "${domain}" 2>/dev/null | awk '$1 ~ /:/ && !seen[$1]++ { print $1 }' >"${output_file}" || true
    fi

    [[ -s "${output_file}" ]] || {
        rm -f "${output_file}"
        return 1
    }
    return 0
}

# Resolution status selects cached fallback behavior.
refresh_manual_domain_cache() {
    local label="$1"
    local domains_file="$2"
    local cache_dir_v4="$3"
    local cache_dir_v6="$4"
    local stage_v4="${TEMP_DIR}/${label}_domains_v4"
    local stage_v6="${TEMP_DIR}/${label}_domains_v6"
    local line domain family extra cache_base
    local any_satisfied=false

    log "INFO" "Refreshing manual ${label} domain cache..."
    mkdir -p "${stage_v4}" "${stage_v6}" || die "Failed to prepare manual ${label} domain staging directories."

    if [[ ! -f "${domains_file}" ]]; then
        log "INFO" "No manual ${label} domain file found at ${domains_file}"
        atomic_swap_directory "${stage_v4}" "${cache_dir_v4}" "${TEMP_DIR}/${label}_domains_v4.backup"
        atomic_swap_directory "${stage_v6}" "${cache_dir_v6}" "${TEMP_DIR}/${label}_domains_v6.backup"
        return 0
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        line="${line%%#*}"
        line="${line%%;*}"
        read -r domain family extra <<<"${line}"
        [[ -z "${domain:-}" ]] && continue
        [[ -z "${extra:-}" ]] || die "Invalid manual ${label} domain entry '${line}'. Use: hostname [A|AAAA|BOTH]"

        domain="${domain,,}"
        family="${family^^}"
        [[ -n "${family}" ]] || family="BOTH"
        case "${family}" in
            A | AAAA | BOTH) ;;
            *) die "Invalid address family '${family}' for manual ${label} domain '${domain}'. Use A, AAAA, or BOTH." ;;
        esac

        # IPv6-only policy entries are inactive when IPv6 filtering is disabled.
        [[ "${GEOBLOCK_IPV6}" == true || "${family}" != AAAA ]] || continue

        cache_base=$(domain_cache_name_from_hostname "${domain}")
        any_satisfied=false

        if [[ "${family}" == "A" || "${family}" == "BOTH" ]]; then
            # shellcheck disable=SC2310
            if resolve_domain_family_to_file "${domain}" A "${stage_v4}/${cache_base}.v4"; then
                any_satisfied=true
            elif [[ -f "${cache_dir_v4}/${cache_base}.v4" ]]; then
                cp --preserve=timestamps -f -- "${cache_dir_v4}/${cache_base}.v4" "${stage_v4}/${cache_base}.v4"
                log "WARN" "Using cached IPv4 entry for manual ${label} domain: ${domain}"
                any_satisfied=true
            elif [[ "${family}" == "A" ]]; then
                die "Failed to resolve required IPv4 record for manual ${label} domain '${domain}' and no cache exists."
            fi
        fi

        if [[ "${GEOBLOCK_IPV6}" == true && ("${family}" == "AAAA" || "${family}" == "BOTH") ]]; then
            # shellcheck disable=SC2310
            if resolve_domain_family_to_file "${domain}" AAAA "${stage_v6}/${cache_base}.v6"; then
                any_satisfied=true
            elif [[ -f "${cache_dir_v6}/${cache_base}.v6" ]]; then
                cp --preserve=timestamps -f -- "${cache_dir_v6}/${cache_base}.v6" "${stage_v6}/${cache_base}.v6"
                log "WARN" "Using cached IPv6 entry for manual ${label} domain: ${domain}"
                any_satisfied=true
            elif [[ "${family}" == "AAAA" ]]; then
                die "Failed to resolve required IPv6 record for manual ${label} domain '${domain}' and no cache exists."
            fi
        fi

        [[ "${any_satisfied}" == true ]] || die "Failed to resolve manual ${label} domain '${domain}' for every requested family and no cache exists."
    done <"${domains_file}"

    atomic_swap_directory "${stage_v4}" "${cache_dir_v4}" "${TEMP_DIR}/${label}_domains_v4.backup"
    atomic_swap_directory "${stage_v6}" "${cache_dir_v6}" "${TEMP_DIR}/${label}_domains_v6.backup"
    log "INFO" "Manual ${label} domain cache refresh complete."
}

# Generate the final, optimized IP list files
# Generation uses checked predicates for optional IPv6 and fallback inputs.
generate_ip_list() {
    log "INFO" "Generating optimized IP range lists..."

    # Enable nullglob so globs like *.v4 expand to empty arrays instead of a
    # literal string when no files match. We restore the previous state before
    # each normal return to avoid leaking shell options into later functions.
    local nullglob_was_enabled=0
    shopt -q nullglob && nullglob_was_enabled=1
    shopt -s nullglob

    [[ -f "${COUNTRY_IPS_DOWNLOADER}" && -x "${COUNTRY_IPS_DOWNLOADER}" ]] || die "${COUNTRY_IPS_DOWNLOADER} script not found/executable"

    # Optimizer command for IPv4: --ipset-reduce merges adjacent/overlapping ranges.
    # IPv6 mode does not support --ipset-reduce on the deployed iprange version.
    local iprange_cmd_v4=(iprange --ipset-reduce 20)
    local iprange_cmd_v6=(iprange)

    # Run the downloader script to get .list.v4 and .list.v6 files
    local downloader_countries_arg
    if [[ "${ALLOWED_COUNTRIES}" == *":"* ]]; then
        log "INFO" "Downloading country IPs using advanced provider syntax: ${ALLOWED_COUNTRIES}"
        downloader_countries_arg="${ALLOWED_COUNTRIES}"
    else
        log "INFO" "Downloading country IPs for: ${ALLOWED_COUNTRIES} (using default provider ${GEO_IP_PROVIDER})"
        downloader_countries_arg="${GEO_IP_PROVIDER}:${ALLOWED_COUNTRIES}"
    fi
    # Try to download fresh country IP lists.
    # The downloader already performs exact per-list fallback from the previous
    # successful cache. If it still fails, continuing with whatever happens to
    # be present in lists/allow could apply a stale allowlist for the wrong
    # country/provider request, so we fail safe here.
    local downloader_require_ipv6=true
    [[ "${GEOBLOCK_IPV6}" == true ]] || downloader_require_ipv6=false

    # shellcheck disable=SC2310
    if ! "${COUNTRY_IPS_DOWNLOADER}" -6 "${downloader_require_ipv6}" -c "${downloader_countries_arg}" -o "${GENERATED_ALLOW_ROOT_DIR}"; then
        die "Country IP download failed. Refusing to apply potentially stale allowlists."
    fi

    download_manual_allow_sources
    refresh_manual_domain_cache allow "${MANUAL_ALLOW_DOMAINS_FILE}" "${ALLOW_DOMAIN_DIR_V4}" "${ALLOW_DOMAIN_DIR_V6}"
    refresh_manual_domain_cache block "${MANUAL_BLOCK_DOMAINS_FILE}" "${BLOCK_DOMAIN_DIR_V4}" "${BLOCK_DOMAIN_DIR_V6}"

    local merged_allow_dir_v4="${TEMP_DIR}/allow_v4_merged"
    local merged_allow_dir_v6="${TEMP_DIR}/allow_v6_merged"
    local final_allow_dir_v4="${TEMP_DIR}/allow_v4_final"
    local final_allow_dir_v6="${TEMP_DIR}/allow_v6_final"
    local final_block_dir_v4="${TEMP_DIR}/block_v4_final"
    local final_block_dir_v6="${TEMP_DIR}/block_v6_final"
    local generated_stage_v4="${TEMP_DIR}/generated_allow_stage.v4"
    local generated_stage_v6="${TEMP_DIR}/generated_allow_stage.v6"
    local effective_stage_v4="${TEMP_DIR}/effective_allow_stage.v4"
    local effective_stage_v6="${TEMP_DIR}/effective_allow_stage.v6"
    mkdir -p "${merged_allow_dir_v4}" "${merged_allow_dir_v6}" "${final_allow_dir_v4}" "${final_allow_dir_v6}" \
        "${final_block_dir_v4}" "${final_block_dir_v6}" ||
        die "Failed to prepare merged allowlist directories."

    # --- Optimize IPv4 List ---
    if [[ "${USE_BLOCKLIST}" == true && -d "${BLOCK_LIST_CLEAN_V4_DIR}" ]] && compgen -G "${BLOCK_LIST_CLEAN_V4_DIR%/}/*" >/dev/null; then
        log "INFO" "Building IPv4 allow base with remote blocklist subtraction..."
        "${iprange_cmd_v4[@]}" @"${ALLOW_LIST_DIR_V4}" --except @"${BLOCK_LIST_CLEAN_V4_DIR}" >"${generated_stage_v4}"
    else
        log "INFO" "Building IPv4 allow base..."
        "${iprange_cmd_v4[@]}" @"${ALLOW_LIST_DIR_V4}" >"${generated_stage_v4}"
    fi

    if [[ -s "${generated_stage_v4}" ]]; then
        cp -f "${generated_stage_v4}" "${merged_allow_dir_v4}/generated.v4"
    else
        log "WARN" "Generated IPv4 allow base is empty after remote blocklist subtraction."
    fi

    copy_directory_contents_if_present "${ALLOW_DOMAIN_DIR_V4}" "${merged_allow_dir_v4}"
    copy_directory_contents_if_present "${ALLOW_SOURCE_DIR_V4}" "${merged_allow_dir_v4}"
    copy_directory_contents_if_present "${MANUAL_ALLOW_LIST_DIR_V4}" "${merged_allow_dir_v4}"
    if [[ -s "${LEGACY_MANUAL_ALLOW_LIST_V4}" ]]; then
        log "WARN" "Legacy manual IPv4 allowlist detected: ${LEGACY_MANUAL_ALLOW_LIST_V4}. Prefer ${MANUAL_ALLOW_LIST_DIR_V4}."
        cp -f "${LEGACY_MANUAL_ALLOW_LIST_V4}" "${merged_allow_dir_v4}/legacy-manual.v4"
    fi

    # shellcheck disable=SC2310
    directory_has_files "${merged_allow_dir_v4}" || die "No IPv4 allowlist inputs available after merging generated, remote, and manual sources."

    log "INFO" "Optimizing IPv4 allow lists..."
    "${iprange_cmd_v4[@]}" @"${merged_allow_dir_v4}" >"${effective_stage_v4}"
    [[ -s "${effective_stage_v4}" ]] || die "Merged IPv4 allowlist is empty. Aborting."

    cp -f "${effective_stage_v4}" "${final_allow_dir_v4}/effective.v4"
    copy_directory_contents_if_present "${BLOCK_DOMAIN_DIR_V4}" "${final_block_dir_v4}"
    copy_directory_contents_if_present "${MANUAL_BLOCK_LIST_DIR_V4}" "${final_block_dir_v4}"
    # shellcheck disable=SC2310
    if directory_has_files "${final_block_dir_v4}"; then
        log "INFO" "Applying manual IPv4 blocklist veto..."
        "${iprange_cmd_v4[@]}" @"${final_allow_dir_v4}" --except @"${final_block_dir_v4}" >"${IP_RANGE_FILE_V4}"
    else
        cp -f "${effective_stage_v4}" "${IP_RANGE_FILE_V4}"
    fi

    # CRITICAL safety check
    [[ -s "${IP_RANGE_FILE_V4}" ]] || die "IPv4 range file ${IP_RANGE_FILE_V4} not found or empty. Aborting."
    log "INFO" "IPv4 range list created at ${IP_RANGE_FILE_V4}"

    # --- Generate IPv6 List ---
    if [[ "${GEOBLOCK_IPV6}" != true ]]; then
        log "INFO" "IPv6 Geo-blocking is disabled (Default). Skipping v6 list generation."
        rm -f "${IP_RANGE_FILE_V6}"
        ((nullglob_was_enabled == 1)) || shopt -u nullglob
        return
    fi

    if [[ "${USE_BLOCKLIST}" == true && -d "${BLOCK_LIST_CLEAN_V6_DIR}" ]] && compgen -G "${BLOCK_LIST_CLEAN_V6_DIR%/}/*" >/dev/null; then
        log "INFO" "Building IPv6 allow base with remote blocklist subtraction..."
        "${iprange_cmd_v6[@]}" -6 @"${ALLOW_LIST_DIR_V6}" --except @"${BLOCK_LIST_CLEAN_V6_DIR}" >"${generated_stage_v6}"
    else
        log "INFO" "Building IPv6 allow base..."
        "${iprange_cmd_v6[@]}" -6 @"${ALLOW_LIST_DIR_V6}" >"${generated_stage_v6}"
    fi

    if [[ -s "${generated_stage_v6}" ]]; then
        cp -f "${generated_stage_v6}" "${merged_allow_dir_v6}/generated.v6"
    else
        log "WARN" "Generated IPv6 allow base is empty after remote blocklist subtraction."
    fi

    copy_directory_contents_if_present "${ALLOW_DOMAIN_DIR_V6}" "${merged_allow_dir_v6}"
    copy_directory_contents_if_present "${ALLOW_SOURCE_DIR_V6}" "${merged_allow_dir_v6}"
    copy_directory_contents_if_present "${MANUAL_ALLOW_LIST_DIR_V6}" "${merged_allow_dir_v6}"
    if [[ -s "${LEGACY_MANUAL_ALLOW_LIST_V6}" ]]; then
        log "WARN" "Legacy manual IPv6 allowlist detected: ${LEGACY_MANUAL_ALLOW_LIST_V6}. Prefer ${MANUAL_ALLOW_LIST_DIR_V6}."
        cp -f "${LEGACY_MANUAL_ALLOW_LIST_V6}" "${merged_allow_dir_v6}/legacy-manual.v6"
    fi

    # shellcheck disable=SC2310
    if ! directory_has_files "${merged_allow_dir_v6}"; then
        die "Required IPv6 allowlist is empty; existing firewall rules retained."
    fi

    log "INFO" "Optimizing IPv6 allow lists..."
    "${iprange_cmd_v6[@]}" -6 @"${merged_allow_dir_v6}" >"${effective_stage_v6}"
    if [[ ! -s "${effective_stage_v6}" ]]; then
        die "Required IPv6 allowlist is empty; existing firewall rules retained."
    fi

    cp -f "${effective_stage_v6}" "${final_allow_dir_v6}/effective.v6"
    copy_directory_contents_if_present "${BLOCK_DOMAIN_DIR_V6}" "${final_block_dir_v6}"
    copy_directory_contents_if_present "${MANUAL_BLOCK_LIST_DIR_V6}" "${final_block_dir_v6}"
    # shellcheck disable=SC2310
    if directory_has_files "${final_block_dir_v6}"; then
        log "INFO" "Applying manual IPv6 blocklist veto..."
        "${iprange_cmd_v6[@]}" -6 @"${final_allow_dir_v6}" --except @"${final_block_dir_v6}" >"${IP_RANGE_FILE_V6}"
    else
        cp -f "${effective_stage_v6}" "${IP_RANGE_FILE_V6}"
    fi

    if [[ ! -s "${IP_RANGE_FILE_V6}" ]]; then
        die "Required IPv6 allowlist is empty; existing firewall rules retained."
    fi

    log "INFO" "IPv6 range list created at ${IP_RANGE_FILE_V6}"
    ((nullglob_was_enabled == 1)) || shopt -u nullglob
}

validate_runtime_lists() {
    [[ -s "${IP_RANGE_FILE_V4}" ]] || die "Required IPv4 allowlist is empty; existing firewall rules retained."
    if [[ "${GEOBLOCK_IPV6}" == true ]]; then
        [[ -s "${IP_RANGE_FILE_V6}" ]] || die "Required IPv6 allowlist is empty; existing firewall rules retained."
    fi
}

###############################################################################
#
# FIREWALL BACKEND: NFTABLES
#
###############################################################################

# Replace only our own table; validation failure leaves the active table unchanged.
apply_rules_nftables() {
    validate_runtime_lists
    log "INFO" "Preparing native nftables filter..."

    # --- Prepare sets (Stream-based approach) ---
    # We write the comma-separated elements to temp files instead of variables
    # to avoid "Argument list too long" or memory issues with massive lists.
    # The limits are available memory and kernel set capacity, not shell argv.

    local v4_elements_file="${TEMP_DIR}/v4_elements.nft"
    paste -s -d, "${IP_RANGE_FILE_V4}" >"${v4_elements_file}"
    local v6_elements_file="${TEMP_DIR}/v6_elements.nft"
    if [[ "${GEOBLOCK_IPV6}" == true ]]; then
        paste -s -d, "${IP_RANGE_FILE_V6}" >"${v6_elements_file}"
    fi

    # --- Generate and Apply Ruleset ---
    local nft_table_exists=false
    if nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
        nft_table_exists=true
    fi

    # Write the complete ruleset to a temp file before touching kernel state.
    # We emit the optional delete together with the new table definition so the
    # kernel sees one atomic nft batch instead of a delete/apply window.
    local nft_config_file="${TEMP_DIR}/nft_ruleset.nft"
    log "INFO" "Generating nftables ruleset..."
    (
        # Derive nftables set elements from the PRIVATE_NETS_* constants (single source of truth).
        local priv_v4_elems priv_v6_elems
        priv_v4_elems=$(printf "%s, " "${PRIVATE_NETS_V4[@]}")
        priv_v4_elems="${priv_v4_elems%, }"
        priv_v6_elems=$(printf "%s, " "${PRIVATE_NETS_V6[@]}")
        priv_v6_elems="${priv_v6_elems%, }"

        if [[ "${nft_table_exists}" == true ]]; then
            echo "delete table inet ${NFT_TABLE_NAME}"
        fi

        cat <<EOF
        table inet ${NFT_TABLE_NAME} {
            # ========= SETS =========
            # These sets contain our whitelisted IPs.

            set private_nets_v4 {
                type ipv4_addr; flags interval; auto-merge;
                elements = { ${priv_v4_elems} }
            }
            set private_nets_v6 {
                type ipv6_addr; flags interval; auto-merge;
                elements = { ${priv_v6_elems} }
            }
            set ${ALLOW_LIST_NAME_V4} {
                type ipv4_addr; flags interval; auto-merge;
                elements = {
EOF
        # Inject IPv4 elements directly from the file stream
        cat "${v4_elements_file}"

        cat <<EOF
                }
            }

            # Bounded per-source SSH meters, independent of GeoIP family selection.
            set ssh_meter_v4 { type ipv4_addr; flags dynamic, timeout; timeout 1m; size 65536; }
            set ssh_meter_v6 { type ipv6_addr; flags dynamic, timeout; timeout 1m; size 65536; }
EOF

        # Conditionally inject IPv6 set only if enabled
        if [[ "${GEOBLOCK_IPV6}" == true ]]; then
            cat <<EOF
            set ${ALLOW_LIST_NAME_V6} {
                type ipv6_addr; flags interval; auto-merge;
                elements = {
EOF
            cat "${v6_elements_file}"
            cat <<EOF
                }
            }
EOF
        fi

        # --- Flowtable Definition ---
        local ft_devs="" ft_trusted=""
        if [[ -n "${FLOWTABLE_INTERFACES}" && -n "${FLOWTABLE_TRUSTED_INTERFACES}" ]]; then
            ft_devs=$(expand_interfaces "${FLOWTABLE_INTERFACES}" true)
            ft_trusted=$(expand_interfaces "${FLOWTABLE_TRUSTED_INTERFACES}")
            if [[ -n "${ft_devs}" && -n "${ft_trusted}" ]]; then
                log "INFO" "Enabling Flowtable (Fasttrack) on interfaces: ${ft_devs}"
                cat <<EOF
            flowtable f {
                hook ingress priority 0;
                devices = { ${ft_devs} };
                counter;
            }
EOF
            else
                log "WARN" "No valid interfaces found for Flowtable (after expansion). Skipping."
                ft_devs=""
            fi
        elif [[ -n "${FLOWTABLE_INTERFACES}" ]]; then
            log "WARN" "Flowtable disabled: set IP_BLOCKER_FLOWTABLE_TRUSTED_INTERFACES to opt in trusted origins."
        fi

        cat <<EOF
            # ========= CHAINS =========

            # One failed set lookup per packet; logging never replaces the drop.
            chain GEOIP_DROP {
                meta nfproto ipv4 limit rate 30/minute burst 10 packets counter log prefix "PREROUTING GEO-DROP: "
                meta nfproto ipv6 limit rate 30/minute burst 10 packets counter log prefix "PREROUTING6 GEO-DROP: "
                counter drop
            }

            # Logging has a global cap per family; exhausting it must never skip DROP.
            chain SSH_RATE_DROP {
                meta nfproto ipv4 limit rate 5/minute burst 5 packets counter log prefix "INPUT SSH RATE-DROP: "
                meta nfproto ipv6 limit rate 5/minute burst 5 packets counter log prefix "INPUT6 SSH RATE-DROP: "
                counter drop
            }

            # --- PREROUTING Chain (Main Gatekeeper) ---
            # Host + forwarded ingress after conntrack (-200), before DNAT (-100).
            # Flowtable hits bypass this hook; offload admission must stay selective.
            chain GEOIP_PREROUTING {
                type filter hook prerouting priority mangle -2; policy accept;

                # 1. Accept critical system/stateful traffic immediately.
                #    'lo' is loopback (localhost).
                #    Established sessions in either direction survive policy refreshes.
                iifname "lo" accept
                ct state established,related accept
                ct state invalid counter drop

                # 2. Trust internal tunnel/bridge traffic regardless of IP geography.
                #    WireGuard authentication happens before packets enter wg*;
                #    the outer UDP handshake on the WAN still passes GeoIP.
                iifname { "wg*", "docker0", "br-*" } accept

                # Accept private networks (Docker, WG, LAN) to bypass Geo-IP.
                #    This prevents locking ourselves out of local management.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept

                # 3. CRITICAL: Allow all ICMPv6 *before* geo-blocking.
                #    NDP and MLD require it; meta l4proto also sees ICMPv6
                #    behind IPv6 extension headers such as Hop-by-Hop.
                meta nfproto ipv6 meta l4proto ipv6-icmp accept

                # 4. Geo-IP v4 Filter (DROP)
                #    Drop all NEW traffic that is NOT in the allowlist.
                ip saddr != @${ALLOW_LIST_NAME_V4} jump GEOIP_DROP

                # 5. Geo-IP v6 Filter (DROP, if enabled)
EOF
        if [[ "${GEOBLOCK_IPV6}" == true ]]; then
            echo '                ip6 saddr != @'"${ALLOW_LIST_NAME_V6}"' jump GEOIP_DROP'
        fi
        cat <<EOF
            }

            # --- FORWARD Chain (Flowtable Offload) ---
            # Admission runs after usual Docker (0) and Fail2ban (-1) priorities.
            # Verify priorities on each host. Already offloaded flows
            # bypass later hooks, so never offload public DNAT connections.
            chain FORWARD {
                type filter hook forward priority filter + 10; policy accept;
EOF
        if [[ -n "${ft_devs}" ]]; then
            cat <<EOF
                # Reply traffic from a container must not make an externally
                # initiated connection eligible. Both interfaces must be opted in.
                ct state established ct direction original ct status & dnat == 0 iifname { ${ft_trusted} } iifname { ${ft_devs} } oifname { ${ft_devs} } meta l4proto { tcp, udp } flow add @f
EOF
        fi
        cat <<EOF
            }

            # --- INPUT Chain (Host Protection) ---
            # Handles traffic *to* this server that has *already passed* PREROUTING.
            # We use 'policy accept' because the main filter is done.
            chain INPUT {
                type filter hook input priority filter - 10; policy accept;

                # 1. Drop invalid packets (redundant but safe).
                ct state invalid counter drop

                # 2. Optimization: Accept established/related traffic immediately.
                #    This avoids checking SSH rules for every packet of an active session.
                ct state related,established accept

                # 3. Optimization: Accept private networks (LAN/Docker/WireGuard) immediately.
                #    GeoIP exemptions do not bypass later base-chain filters.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept
                # Trust local interfaces and WireGuard
                iifname { "lo", "docker0" } accept
                iifname "wg*" accept
                iifname "br-*" accept

                # 4. Allow only successful, under-limit meter evaluations.
                # A full set/allocation failure skips the rest of its rule, so
                # the separate fallback must DROP, not accept untracked sources.
                # Base-chain accept still permits later host firewall hooks.
                tcp dport ${SSH_PORT} ct state new update @ssh_meter_v4 { ip saddr limit rate 10/second } counter accept
                tcp dport ${SSH_PORT} ct state new update @ssh_meter_v6 { ip6 saddr limit rate 10/second } counter accept
                tcp dport ${SSH_PORT} ct state new counter jump SSH_RATE_DROP
            }

        }
EOF
    ) >"${nft_config_file}"
    # iprange and interval auto-merge already normalize the sets; no extra
    # optimizer pass, which has conflicted with auto-merge in deployed versions.

    [[ -s "${nft_config_file}" ]] || die "Generated nftables config is empty. Aborting to preserve existing rules."

    if ! nft -c -f "${nft_config_file}"; then
        die "Generated nftables config failed validation. Existing rules were left untouched."
    fi

    log "INFO" "Replacing ${NFT_TABLE_NAME} table atomically..."
    if ! nft -f "${nft_config_file}"; then
        die "nftables ruleset application failed. Existing rules were left untouched."
    fi

    log "INFO" "nftables ruleset applied successfully."
}

###################
# Main Logic
###################
# Blocklist download status selects online or cached operation.
main() {
    local started=${SECONDS}
    # Validate CLI and environment configuration before requiring root.
    parse_arguments "$@"
    if [[ "${CHECK_CONFIG}" == true ]]; then
        printf 'ip_blocker configuration is valid\n'
        return 0
    fi

    # Check root, create the secure staging directory and install traps.
    setup_temp_dir_and_traps
    log_dns_config

    check_installed_commands
    nft list tables >/dev/null || die "Cannot access native nftables; no changes applied."

    # Prepare the persistent cache and manual policy directories.
    mkdir -p \
        "${ALLOW_LIST_DIR_V4}" "${ALLOW_LIST_DIR_V6}" \
        "${ALLOW_SOURCE_DIR_V4}" "${ALLOW_SOURCE_DIR_V6}" \
        "${ALLOW_DOMAIN_DIR_V4}" "${ALLOW_DOMAIN_DIR_V6}" \
        "${MANUAL_ALLOW_LIST_DIR_V4}" "${MANUAL_ALLOW_LIST_DIR_V6}" \
        "${BLOCK_LIST_DIR}" "${BLOCK_LIST_DIR_V4}" "${BLOCK_LIST_DIR_V6}" \
        "${BLOCK_DOMAIN_DIR_V4}" "${BLOCK_DOMAIN_DIR_V6}" \
        "${MANUAL_BLOCK_LIST_DIR_V4}" "${MANUAL_BLOCK_LIST_DIR_V6}" ||
        die "Failed to create directories"

    # Never silently disable requested blocking when its inputs are unusable.
    if [[ "${USE_BLOCKLIST}" == true ]]; then
        # shellcheck disable=SC2310
        download_blocklists || die "Blocklist refresh failed without complete validated fallback; live rules unchanged."
        separate_ip_families
    fi

    # Generate final ranges; unusable required inputs abort before kernel changes.
    generate_ip_list

    apply_rules_nftables

    local count_v4 count_v6=0
    count_v4=$(wc -l <"${IP_RANGE_FILE_V4}")
    [[ "${GEOBLOCK_IPV6}" == false ]] || count_v6=$(wc -l <"${IP_RANGE_FILE_V6}")
    log "INFO" "Applied ${count_v4} IPv4 and ${count_v6} IPv6 networks in $((SECONDS - started))s."
    log "INFO" "Configuration completed successfully."
}

# Pass all command-line arguments to the main function
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
