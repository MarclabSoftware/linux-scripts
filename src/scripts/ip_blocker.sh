#!/usr/bin/env bash

# IP-Based Firewall Configuration Script
# Version: 6.0.0
# Updated: 2026-07-29
#
# Configures a robust, hybrid-backend firewall (nftables/iptables) with a
# focus on Geo-IP filtering, SSH brute-force mitigation, and Docker protection.
# Supports renamed interfaces and standard wildcard patterns; interfaces that
# do not exist are safely ignored.
#
# Core Features:
# - Auto-Backend: Prefers 'nftables', falls back to 'iptables'/'ipset'.
# - Geo-IP Filtering: Full IPv4 & optional IPv6. Supports multiple providers
#   (ipdeny, ripe, nirsoft) plus persistent manual 'lists/manual.v4' and
#   'lists/manual.v6' files via iprange 2.0.
# - Flowtable Offload: Hardware/Software offload for established connections
#   (nftables only) to boost throughput and reduce CPU load.
# - Default Deny Policy: Secures the host (INPUT) while safely filtering
#   Docker traffic (FORWARD) before Docker's own rules.
# - Protection: Robust SSH rate-limiting (v4/v6) using meters (nft) or recent
#   module (iptables), plus full Blocklist support (v4/v6).
# - Safe & Atomic: Applies rules in a single transaction to prevent errors.
# - Robust: Includes connectivity checks, fail-fast downloads, resilient HTML
#   content rejection for lists, and smart error trapping.
#
# Usage:
#   sudo ./ip_blocker.sh [-c COUNTRIES] [-p PROVIDER] [-b] [-G] [-s SSH_PORT] [-i INTERFACES] [-h]
#
# Options:
#   -c countries   Specify allowed countries.
#                  Simple: "IT,DE,FR" (uses provider from -p).
#                  Advanced: "ripe:IT,FR;ipdeny:CN;nirsoft:KR,IT" (ignores -p).
#   -p provider    Geo-IP provider: 'ipdeny', 'ripe', 'nirsoft' (default: ipdeny)
#   -b             Enable block lists (IPv4 always; IPv6 if -G is enabled).
#   -G             Enable Geo-blocking for IPv6 (default: false, IPv6 is allowed).
#   -s sshPort     Specify the SSH port (default: 22).
#   -i interfaces  List of interfaces for Flowtable offload (e.g. "eth0 wg0").
#                  Supports wildcards (e.g. "br-* wg* eth*").
#   -h             Display this help message.
#
# Environment:
#   DNS_SERVERS    Custom DNS servers for early-boot resolution (e.g. "8.8.8.8 1.1.1.1")
#
# Enable strict mode:
# -E: Inherit traps (ERR, DEBUG, RETURN) in functions.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: The return value of a pipeline is the status of the last
#              command to exit with a non-zero status, or zero if all exit ok.
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
declare -r IPTABLES_CHAIN_PREFIX="${IP_BLOCKER_IPTABLES_CHAIN_PREFIX:-IPBLOCKER}"
# Names for our sets/ipsets
declare -r ALLOW_LIST_NAME_V4="allowlist_v4"
declare -r ALLOW_LIST_NAME_V6="allowlist_v6"
# Geo-IP Provider settings
# Default provider if -p is not used
declare -r DEFAULT_PROVIDER="${IP_BLOCKER_PROVIDER:-ipdeny}"
declare -ra ALLOWED_PROVIDERS=(ipdeny ripe nirsoft)
# Max retries for downloader
declare -r MAX_RETRIES="${IP_BLOCKER_MAX_RETRIES:-3}"
# Sites to test connectivity (DNS resolution + TCP, via curl HEAD)
read -r -a CONNECTIVITY_CHECK_SITES <<<"${IP_BLOCKER_CONNECTIVITY_CHECK_SITES:-github.com google.com}"
declare -r CONNECTIVITY_CHECK_SITES
# How long to wait for DNS/network to come up (seconds). Relevant at boot.
declare -r CONNECTIVITY_MAX_WAIT="${IP_BLOCKER_CONNECTIVITY_MAX_WAIT:-120}"
# Interval between connectivity retries (seconds)
declare -r CONNECTIVITY_RETRY_INTERVAL="${IP_BLOCKER_CONNECTIVITY_RETRY_INTERVAL:-10}"
# Lock directory for singleton execution
declare -r LOCK_DIR="${IP_BLOCKER_LOCK_DIR:-/run/ip_blocker.lock}"
# RFC 1918 private IPv4 ranges plus the unspecified address used by DHCP/BOOTP
# clients before configuration — used in both nftables sets and iptables rules.
declare -ra PRIVATE_NETS_V4=("0.0.0.0/32" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
# Link-local, ULA, and multicast IPv6 ranges — must always bypass Geo-IP.
declare -ra PRIVATE_NETS_V6=("fe80::/10" "fc00::/7" "ff00::/8")
# Interfaces used for POSTROUTING masquerade (NAT).
# Wildcards are expanded by the firewall backend:
#   nftables: oifname "eth*"    (native glob, safe if iface doesn't exist)
#   iptables: -o eth+           ('+' = kernel wildcard, safe if iface doesn't exist)
read -r -a NAT_INTERFACES <<<"${IP_BLOCKER_NAT_INTERFACES:-eth* en*}"
declare -r NAT_INTERFACES

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
declare CHECK_CONFIG=false

# Secure temp directory
declare TEMP_DIR=""
# Final optimized IP list files (path is set in setup_temp_dir_and_traps)
declare IP_RANGE_FILE_V4=""
declare IP_RANGE_FILE_V6=""

declare CLEANUP_REGISTERED=false
declare FIREWALL_BACKEND=""
declare -a REQUIRED_COMMANDS=()
declare URL_PARSE_HOST=""
declare URL_PARSE_PORT=""

# Paths for clean intermediate lists
# Paths for clean intermediate lists are now persistent
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
# @return Space-separated IPs
_resolve_hostname() {
    local host="$1"
    [[ -z "${DNS_SERVERS:-}" ]] && return 0
    # Return from cache if available
    [[ -n "${RESOLVED_HOSTS_CACHE[${host}]:-}" ]] && echo "${RESOLVED_HOSTS_CACHE[${host}]}" && return 0

    local -a ips=()
    local -a servers=()
    local -a resolved=()
    local -a rrtypes=(A AAAA)
    local ip
    local rrtype
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        read -ra servers <<<"${DNS_SERVERS:-}"
    fi

    # Try each DNS server until one succeeds
    for ns in "${servers[@]}"; do
        for rrtype in "${rrtypes[@]}"; do
            mapfile -t resolved < <(dig +short "@${ns}" "${host}" "${rrtype}" 2>/dev/null || true)
            for ip in "${resolved[@]}"; do
                if [[ "${rrtype}" == "A" ]]; then
                    [[ "${ip}" == *.*.*.* ]] || continue
                else
                    [[ "${ip}" == *:* ]] || continue
                fi
                ips+=("${ip}")
            done
        done
        if [[ ${#ips[@]} -gt 0 ]]; then
            break # Stop at first successful resolver
        fi
    done

    if [[ ${#ips[@]} -gt 0 ]]; then
        RESOLVED_HOSTS_CACHE[${host}]="${ips[*]}"
        echo "${ips[*]}"
    fi
}
export -f _resolve_hostname

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
    resolved_ips=$(_resolve_hostname "${URL_PARSE_HOST}")
    read -ra ips <<<"${resolved_ips}"
    for ip in "${ips[@]}"; do
        resolve_ip="${ip}"
        [[ "${resolve_ip}" == *:* ]] && resolve_ip="[${resolve_ip}]"
        options+=("--resolve" "${URL_PARSE_HOST}:${URL_PARSE_PORT}:${resolve_ip}")
    done

    printf -v "${result_var}" '%s' "${options[*]-}"
}

# Cheap HTML/XML detector without spawning head/grep for every file.
file_has_markup_header() {
    local file="$1"
    local line
    local checked=0

    while IFS= read -r line && ((checked < 50)); do
        line="${line,,}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        ((checked++))
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
    if [[ "${CLEANUP_REGISTERED}" == true ]]; then
        log "INFO" "Performing cleanup..."
        if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
            rm -rf "${TEMP_DIR}"
            log "INFO" "Removed temporary directory: ${TEMP_DIR}"
        fi
        if [[ -d "${LOCK_DIR}" ]]; then
            rm -rf "${LOCK_DIR}"
            log "INFO" "Released lock: ${LOCK_DIR}"
        fi
    fi
}

# Check for root, create secure temp dir, and setup traps
setup_temp_dir_and_traps() {
    # 1. Check root
    [[ "${EUID}" -ne 0 ]] && die "Please run as root/sudo"

    # 2. Acquire Lock (Atomic mkdir)
    # This prevents multiple instances from running simultaneously.
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        # Check if the process holding the lock is still alive
        if [[ -f "${LOCK_DIR}/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "${LOCK_DIR}/pid")
            if kill -0 "${lock_pid}" 2>/dev/null; then
                die "Script is already running (PID: ${lock_pid}). Aborting."
            else
                log "WARN" "Stale lock found (PID: ${lock_pid}). Removing..."
                rm -rf "${LOCK_DIR}"
                # Try to acquire again
                if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
                    die "Failed to acquire lock after removing stale lock."
                fi
            fi
        else
            # No PID file: lock is stale (e.g. SIGKILL during setup). Remove and retry.
            log "WARN" "Lock exists without PID file. Assuming stale, removing."
            rm -rf "${LOCK_DIR}"
            if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
                die "Failed to acquire lock after removing stale lock (concurrent start?)."
            fi
        fi
    fi
    # Write our PID to the lock
    echo "$$" >"${LOCK_DIR}/pid"

    # 3. Create secure temp directory under the persistent list root.
    # Keeping staging on the same filesystem as the target directories preserves
    # O(1) rename semantics for our directory swaps.
    mkdir -p "${IP_LIST_DIR}" || die "Failed to prepare list root directory"
    TEMP_DIR=$(mktemp -d "${IP_LIST_DIR}/.ipblocker.XXXXXX") || die "Failed to create secure temp directory"

    # 4. Set global paths for our temp files
    IP_RANGE_FILE_V4="${TEMP_DIR}/${ALLOW_LIST_NAME_V4}.iprange.txt"
    IP_RANGE_FILE_V6="${TEMP_DIR}/${ALLOW_LIST_NAME_V6}.iprange.txt"

    # 5. Setup traps (now that TEMP_DIR and Lock are set)
    setup_signal_handlers
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
    -h             Display this help message
EOF
    exit "${exit_code}"
}

# Parse command line arguments using getopts
parse_arguments() {
    if [[ $# -eq 0 ]]; then
        log "INFO" "No CLI arguments provided; using environment configuration."
    fi
    OPTIND=1
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
    [[ "${IPTABLES_CHAIN_PREFIX}" =~ ^[A-Z][A-Z0-9_]{0,15}$ ]] ||
        die "IP_BLOCKER_IPTABLES_CHAIN_PREFIX must be 1-16 uppercase letters, digits or underscores"
    for integer_setting in MAX_RETRIES CONNECTIVITY_MAX_WAIT CONNECTIVITY_RETRY_INTERVAL; do
        [[ "${!integer_setting}" =~ ^[1-9][0-9]*$ ]] ||
            die "${integer_setting} must be a positive integer"
    done
    ((${#CONNECTIVITY_CHECK_SITES[@]} > 0)) ||
        die "IP_BLOCKER_CONNECTIVITY_CHECK_SITES must not be empty"

    # Validate SSH port is a valid number
    if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]] || [[ "${SSH_PORT}" -lt 1 ]] || [[ "${SSH_PORT}" -gt 65535 ]]; then
        die "SSH port must be a number between 1 and 65535"
    fi
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
        done
    else
        # Simple syntax (e.g., "IT,FR,DE")
        if [[ ! "${ALLOWED_COUNTRIES}" =~ ^[A-Za-z]{2}(,[A-Za-z]{2})*$ ]]; then
            die "Country codes must be 2-letter ISO codes, comma-separated (e.g., IT,FR,DE)"
        fi

        [[ " ${ALLOWED_PROVIDERS[*]} " == *" ${GEO_IP_PROVIDER} "* ]] ||
            die "Invalid provider '${GEO_IP_PROVIDER}'. Allowed: ${ALLOWED_PROVIDERS[*]}"
        log "INFO" "Using Geo-IP provider: ${GEO_IP_PROVIDER}"
    fi
}

###################
# System & Network Checks
###################

# Check for internet connectivity before attempting downloads.
# Uses curl (not ping) to test both DNS resolution AND TCP/HTTPS reachability.
# Ping can succeed from kernel-cached routes while the DNS resolver is still starting
# Retries for up to CONNECTIVITY_MAX_WAIT seconds to give DNS time to come up.
check_connectivity() {
    log "INFO" "Checking connectivity (DNS + TCP, up to ${CONNECTIVITY_MAX_WAIT}s)..."
    local elapsed=0

    while ((elapsed < CONNECTIVITY_MAX_WAIT)); do
        for site in "${CONNECTIVITY_CHECK_SITES[@]}"; do
            local -a resolve_opts=()
            local resolve_opts_str=""
            if [[ -n "${DNS_SERVERS:-}" ]]; then
                build_resolve_options_for_url "https://${site}" resolve_opts_str
                [[ -n "${resolve_opts_str}" ]] && read -ra resolve_opts <<<"${resolve_opts_str}"
            fi

            # -f: fail on HTTP error  --head: no body download
            # --connect-timeout: abort if TCP handshake takes > 5s
            # --max-time: hard cap on the entire request
            if curl -fsSL "${resolve_opts[@]}" --head --connect-timeout 5 --max-time 10 "https://${site}" >/dev/null 2>&1; then
                log "INFO" "Connectivity check passed (${site}, ${elapsed}s after start)"
                return 0
            fi
        done

        ((elapsed += CONNECTIVITY_RETRY_INTERVAL))
        if ((elapsed < CONNECTIVITY_MAX_WAIT)); then
            log "WARN" "DNS/network not ready. Retrying in ${CONNECTIVITY_RETRY_INTERVAL}s... (${elapsed}s/${CONNECTIVITY_MAX_WAIT}s)"
            sleep "${CONNECTIVITY_RETRY_INTERVAL}"
        fi
    done

    die "Connectivity check failed after ${CONNECTIVITY_MAX_WAIT}s. DNS or network unavailable."
}

# Detects the best available firewall backend (nftables or iptables)
detect_backend() {
    log "INFO" "Detecting firewall backend..."
    if command -v nft &>/dev/null; then
        FIREWALL_BACKEND="nftables"
        REQUIRED_COMMANDS=(curl iprange nft grep sed awk cp getent)
        [[ "${USE_BLOCKLIST}" == true ]] && REQUIRED_COMMANDS+=(cksum)
        log "INFO" "Backend selected: nftables (native)"

        # Pre-flight check: Verify nftables functionality
        # This catches issues like missing kernel modules or permission errors early.
        if ! nft list tables >/dev/null 2>&1; then
            die "nftables detected but 'nft list tables' failed. Check kernel support or permissions."
        fi

    elif command -v iptables &>/dev/null && command -v ipset &>/dev/null; then
        FIREWALL_BACKEND="iptables"
        # Dynamically add IPv6 tools only if needed
        REQUIRED_COMMANDS=(curl ipset iptables iprange iptables-restore iptables-save grep sed awk cp getent)
        [[ "${USE_BLOCKLIST}" == true ]] && REQUIRED_COMMANDS+=(cksum)
        if [[ "${GEOBLOCK_IPV6}" == true ]]; then
            REQUIRED_COMMANDS+=(ip6tables ip6tables-restore ip6tables-save)
        fi
        log "INFO" "Backend selected: iptables (legacy)"
    else
        die "No supported firewall backend found. Need 'nft' or 'iptables'/'ipset'."
    fi
}

# Verify that all dynamically required commands are installed
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

retry_command() {
    local retries=0
    local -a cmd=("$@")

    while ((retries < MAX_RETRIES)); do
        # Use an 'if' statement to prevent 'set -e' from exiting the script
        # if the command fails, allowing the loop to handle the error.
        if "${cmd[@]}"; then
            return 0 # Success
        fi

        ((retries++))
        log "WARN" "Command failed: ${cmd[*]}. Retry ${retries}/${MAX_RETRIES}"
        sleep $((2 ** retries)) # 2s, 4s, 8s
    done

    die "Command failed after ${MAX_RETRIES} retries: ${cmd[*]}"
}

# Like retry_command but returns 1 instead of calling die on exhausted retries.
# Use for optional/degradable operations (e.g. blocklist download) where the
# caller decides whether failure is fatal.
try_command() {
    local retries=0
    local -a cmd=("$@")

    while ((retries < MAX_RETRIES)); do
        if "${cmd[@]}"; then
            return 0
        fi
        ((retries++))
        log "WARN" "Command failed: ${cmd[*]}. Retry ${retries}/${MAX_RETRIES}"
        sleep $((2 ** retries))
    done

    log "WARN" "Command failed after ${MAX_RETRIES} retries (non-fatal): ${cmd[*]}"
    return 1
}

restore_iptables_backup() {
    local restore_cmd="$1"
    local backup_file="$2"
    local label="$3"

    [[ -s "${backup_file}" ]] || return 1

    if "${restore_cmd}" <"${backup_file}"; then
        log "INFO" "Rollback successful for ${label}."
        return 0
    fi

    log "ERROR" "Rollback failed for ${label}."
    return 1
}

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
# shellcheck disable=SC2310
cached_blocklist_file_is_valid() {
    local cached_file="$1"

    [[ -s "${cached_file}" ]] || return 1
    ! file_has_markup_header "${cached_file}"
}

backup_ipset_state() {
    local set_name="$1"
    local backup_file="$2"

    if ipset list "${set_name}" >/dev/null 2>&1; then
        ipset save "${set_name}" >"${backup_file}" || die "Failed to back up ipset '${set_name}'"
    else
        : >"${backup_file}"
    fi
}

restore_ipset_backup() {
    local set_name="$1"
    local backup_file="$2"
    local restore_file="${TEMP_DIR}/${set_name}.rollback.restore"

    if [[ -s "${backup_file}" ]]; then
        if ! awk '
            $1 == "create" {
                print $0 " -exist"
                print "flush " $2
                next
            }
            $1 == "add" { print }
        ' "${backup_file}" >"${restore_file}"; then
            log "ERROR" "Failed to prepare rollback payload for ipset '${set_name}'."
            return 1
        fi

        if ipset restore <"${restore_file}"; then
            log "INFO" "Rollback successful for ipset '${set_name}'."
            return 0
        fi

        log "ERROR" "Rollback failed for ipset '${set_name}'."
        return 1
    fi

    if ipset destroy "${set_name}" 2>/dev/null || { ipset flush "${set_name}" 2>/dev/null && ipset destroy "${set_name}" 2>/dev/null; }; then
        log "INFO" "Removed transient ipset '${set_name}' during rollback."
        return 0
    fi

    if ipset list "${set_name}" >/dev/null 2>&1; then
        log "ERROR" "Failed to remove transient ipset '${set_name}' during rollback."
        return 1
    fi

    return 0
}

cleanup_legacy_ipset() {
    local set_name="$1"

    command -v ipset >/dev/null 2>&1 || return 0
    ipset list "${set_name}" >/dev/null 2>&1 || return 0

    if ipset destroy "${set_name}" 2>/dev/null; then
        log "INFO" "Removed legacy ipset '${set_name}'."
        return 0
    fi

    ipset flush "${set_name}" 2>/dev/null || true
    if ipset destroy "${set_name}" 2>/dev/null; then
        log "INFO" "Removed legacy ipset '${set_name}' after flush."
        return 0
    fi

    log "WARN" "Failed to remove legacy ipset '${set_name}'."
    return 1
}

# Rollback helpers are best-effort and aggregate failures explicitly.
# shellcheck disable=SC2310
rollback_iptables_runtime_state() {
    local iptables_backup_file="$1"
    local ip6tables_backup_file="$2"
    local ipset_backup_v4="$3"
    local ipset_backup_v6="$4"
    local rollback_failed=0

    restore_iptables_backup iptables-restore "${iptables_backup_file}" "iptables" || rollback_failed=1

    if [[ -s "${ip6tables_backup_file}" ]]; then
        restore_iptables_backup ip6tables-restore "${ip6tables_backup_file}" "ip6tables" || rollback_failed=1
    fi

    restore_ipset_backup "${ALLOW_LIST_NAME_V4}" "${ipset_backup_v4}" || rollback_failed=1

    if [[ -n "${ipset_backup_v6}" && (-s "${ipset_backup_v6}" || "${GEOBLOCK_IPV6}" == true) ]]; then
        restore_ipset_backup "${ALLOW_LIST_NAME_V6}" "${ipset_backup_v6}" || rollback_failed=1
    fi

    return "${rollback_failed}"
}

# Replaces a directory with a fully prepared staging directory using O(1) renames.
atomic_swap_directory() {
    local new_dir="$1"
    local target_dir="$2"
    local backup_dir="$3"
    local parent_dir="${target_dir%/*}"

    [[ -d "${new_dir}" ]] || die "Atomic swap source directory not found: ${new_dir}"
    [[ "${parent_dir}" == "${target_dir}" ]] || mkdir -p "${parent_dir}"

    if [[ -d "${target_dir}" ]]; then
        mv "${target_dir}" "${backup_dir}" || die "Failed to move existing directory '${target_dir}' to backup"
    fi

    if mv "${new_dir}" "${target_dir}"; then
        rm -rf "${backup_dir}"
        return 0
    fi

    log "ERROR" "Failed to activate new directory '${target_dir}'. Attempting rollback."
    if [[ -d "${backup_dir}" ]]; then
        mv "${backup_dir}" "${target_dir}" || log "ERROR" "Rollback failed for '${target_dir}'"
    fi
    die "Atomic directory swap failed for '${target_dir}'"
}

# Helper to expand interface wildcards (e.g. "eth0 br-*")
expand_interfaces() {
    local input_patterns="$1"
    local -a expanded_list=()
    local -a unique_list=()
    local match
    local iface
    local joined=""
    declare -A seen_ifaces=()

    for pattern in ${input_patterns}; do
        if [[ "${pattern}" == *"*"* ]]; then
            # Expand wildcard using /sys/class/net
            # Expand wildcard using compgen to avoid SC2206
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

    # Deduplicate while preserving discovery order, then join with commas.
    for iface in "${expanded_list[@]}"; do
        [[ -n "${seen_ifaces[${iface}]:-}" ]] && continue
        seen_ifaces[${iface}]=1
        unique_list+=("${iface}")
    done

    for iface in "${unique_list[@]}"; do
        joined+="${joined:+,}${iface}"
    done

    [[ -n "${joined}" ]] && printf '%s\n' "${joined}"
}

###################
# List Generation
###################

# Download and process blocklists
# Download and cache helpers return status used for fallback selection.
# shellcheck disable=SC2310
download_blocklists() {
    log "INFO" "Downloading blocklists..."

    # Only 'log' is needed in '& ' subshells; retry_command/die are not called there.
    export -f log

    # Limit background parsers to avoid a process burst on tiny machines.
    # Limit background parsers to avoid a process burst on tiny machines.
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

    if ! try_command curl -fsSL "${index_resolve_opts[@]}" --connect-timeout 10 --max-time 30 "${BLOCK_LIST_URL}" -o "${BLOCK_LIST_FILE_NAME}"; then
        if [[ -f "${BLOCK_LIST_FILE_NAME}" ]]; then
            log "WARN" "Blocklist index unreachable; using cached index from previous run."
        else
            log "WARN" "Blocklist index unreachable and no cached index found. Skipping blocklists."
            return 1
        fi
    fi

    while IFS= read -r line; do
        [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
        line="${line//$'\r'/}"
        urls+=("${line}")
    done <"${BLOCK_LIST_FILE_NAME}"

    # 2. Parse additional manual blocklist sources (canonical path first).
    if [[ -f "${MANUAL_BLOCK_SOURCES_FILE}" ]]; then
        log "INFO" "Adding manual blocklist sources from ${MANUAL_BLOCK_SOURCES_FILE}"
        while IFS= read -r line; do
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            line="${line//$'\r'/}"
            urls+=("${line}")
        done <"${MANUAL_BLOCK_SOURCES_FILE}"
    fi

    if [[ -f "${LEGACY_MANUAL_BLOCK_SOURCES_FILE}" ]]; then
        log "WARN" "Legacy manual blocklist source file detected: ${LEGACY_MANUAL_BLOCK_SOURCES_FILE}. Prefer ${MANUAL_BLOCK_SOURCES_FILE}."
        while IFS= read -r line; do
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            line="${line//$'\r'/}"
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
    done

    if ((${#expected_files[@]} == 0)); then
        log "WARN" "No blocklist sources configured after parsing."
        shopt -s nullglob
        local cached_existing=("${BLOCK_LIST_DIR}"/*)
        shopt -u nullglob
        if ((${#cached_existing[@]} > 0)); then
            log "WARN" "Using ${#cached_existing[@]} cached blocklist file(s) from previous run."
            return 0
        fi
        return 1
    fi

    # 3. Download ALL Lists into a staging directory (inside TEMP_DIR).
    # Atomic strategy: download to staging first, then replace BLOCK_LIST_DIR only
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
                local url="${scheduled_files[${cache_name}]}"
                if [[ -n "${DNS_SERVERS:-}" ]]; then
                    build_resolve_options_for_url "${url}" resolve_opts_str
                    [[ -n "${resolve_opts_str}" ]] && read -ra resolve_opts <<<"${resolve_opts_str}"
                fi

                log "INFO" "Downloading: ${url}"
                if ! curl_err=$(curl -fsSL "${resolve_opts[@]}" -o "${cache_name}" --connect-timeout 15 --max-time 90 "${url}" 2>&1); then
                    log "WARN" "Failed to download ${url}: ${curl_err%%$'\n'*}"
                elif file_has_markup_header "${cache_name}"; then
                    log "WARN" "Downloaded blocklist appears to contain HTML/XML and will be discarded: ${url}"
                    rm -f -- "${cache_name}"
                fi
            ) &
        done
        wait || true
    )

    # 4. Validate results and satisfy partial failures from the exact same cached list.
    local -i total ok failed
    local staged_file cached_file
    total=${#expected_files[@]}
    ok=0

    for cache_name in "${expected_files[@]}"; do
        staged_file="${staging_dir}/${cache_name}"
        if cached_blocklist_file_is_valid "${staged_file}"; then
            ((ok++))
            continue
        fi

        rm -f -- "${staged_file}"
        cached_file="${BLOCK_LIST_DIR}/${cache_name}"
        if cached_blocklist_file_is_valid "${cached_file}"; then
            cp -f -- "${cached_file}" "${staged_file}" || die "Failed to restore cached blocklist '${cache_name}'"
            log "WARN" "Using cached blocklist for unavailable source: ${cache_name}"
            ((ok++))
            continue
        fi

        missing_blocklist_files+=("${cache_name}")
    done

    failed=$((total - ok))
    if ((${#missing_blocklist_files[@]} > 0)); then
        shopt -s nullglob
        local cached=("${BLOCK_LIST_DIR}"/*)
        shopt -u nullglob
        if ((${#cached[@]} > 0)); then
            log "WARN" "Blocklist download incomplete (${ok}/${total} ready, ${failed} missing). Missing same-list cache for: ${missing_blocklist_files[*]}. Preserving previous raw blocklist directory."
            return 0
        fi
        log "WARN" "Blocklist download incomplete (${ok}/${total} ready, ${failed} missing) and no previous raw blocklist cache exists. Blocklist filtering will be skipped."
        return 1
    fi

    log "INFO" "Blocklist download summary: ${ok}/${total} ready, ${failed} missing."
    atomic_swap_directory "${staging_dir}" "${BLOCK_LIST_DIR}" "${TEMP_DIR}/block_raw.backup"
    log "INFO" "Blocklist download complete."
}

# Pre-process downloaded lists to separate v4 and v6 content
# This prevents iprange from misinterpreting IPv6 addresses as DNS names
# Markup detection is intentionally used as a validation predicate.
# shellcheck disable=SC2310
separate_ip_families() {
    log "INFO" "Separating IPv4 and IPv6 addresses from raw blocklists..."

    # Enable nullglob to handle empty dirs
    shopt -s nullglob
    local raw_files=("${BLOCK_LIST_DIR}"/*)
    shopt -u nullglob

    if [[ ${#raw_files[@]} -eq 0 ]]; then
        log "WARN" "No blocklist files found to process."
        return
    fi

    local v4_clean_dir="${TEMP_DIR}/block_v4_clean"
    local v6_clean_dir="${TEMP_DIR}/block_v6_clean"
    mkdir -p "${v4_clean_dir}" "${v6_clean_dir}"

    local max_jobs=8

    log "INFO" "Processing ${#raw_files[@]} files..."

    for file in "${raw_files[@]}"; do
        local filename
        filename=$(basename "${file}")

        # Sanity check: reject HTML/XML responses (captive portals, 404 pages).
        # The helper scans the first significant non-empty lines, which is enough
        # for real-world error pages while staying cheaper than a full parse.
        if file_has_markup_header "${file}"; then
            log "WARN" "File '${filename}' appears to be HTML/XML (invalid content). Skipping."
            continue
        fi

        wait_for_job_slot_limit "${max_jobs}"
        (
            local out_v4="${v4_clean_dir}/${filename}.v4"
            local out_v6="${v6_clean_dir}/${filename}.v6"
            local want_v6=0
            [[ "${GEOBLOCK_IPV6}" == true ]] && want_v6=1

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
                    if (split(addr_range, parts, /[[:space:]]+-[[:space:]]+/) != 2) return 0
                    if (parts[1] ~ /\// || parts[2] ~ /\// || !is_valid_ipv4(parts[1]) || !is_valid_ipv4(parts[2])) return 0
                    start_ip = ipv4_to_int(parts[1])
                    end_ip = ipv4_to_int(parts[2])
                    return (start_ip <= end_ip)
                }
                {
                    sub(/\r$/, "", $0)
                    # Some feeds (for example Spamhaus DROPv6) annotate entries
                    # with semicolon comments instead of hash comments.
                    sub(/[[:space:]]*[#;].*$/, "", $0)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
                    if ($0 == "") next

                    if (is_valid_ipv4($0) || is_valid_ipv4_range($0)) {
                        print >> out_v4
                        next
                    }

                    if (want_v6 && is_valid_ipv6($0)) {
                        print >> out_v6
                    }
                }
            ' "${file}"
        ) &
    done
    wait || true

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
# shellcheck disable=SC2310
copy_directory_contents_if_present() {
    local src_dir="$1"
    local dst_dir="$2"
    local -a files=()

    directory_has_files "${src_dir}" || return 0
    files=("${src_dir}"/*)
    cp -f "${files[@]}" "${dst_dir}"/
}

# Markup detection is intentionally used as a validation predicate.
# shellcheck disable=SC2310
split_ip_families_from_file() {
    local input_file="$1"
    local out_v4="$2"
    local out_v6="$3"
    local want_v6=0

    [[ "${GEOBLOCK_IPV6}" == true ]] && want_v6=1

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
            if (split(addr_range, parts, /[[:space:]]+-[[:space:]]+/) != 2) return 0
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
                print >> out_v4
                next
            }

            if (want_v6 && is_valid_ipv6($0)) {
                print >> out_v6
            }
        }
    ' "${input_file}"
}

# Per-source parsing failures are handled without aborting other sources.
# shellcheck disable=SC2310
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
        while IFS= read -r line; do
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            line="${line//$'\r'/}"
            urls+=("${line}")
        done <"${MANUAL_ALLOW_SOURCES_FILE}"
    fi

    if [[ -f "${LEGACY_MANUAL_ALLOW_SOURCES_FILE}" ]]; then
        log "WARN" "Legacy manual allowlist source file detected: ${LEGACY_MANUAL_ALLOW_SOURCES_FILE}. Prefer ${MANUAL_ALLOW_SOURCES_FILE}."
        while IFS= read -r line; do
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
            line="${line//$'\r'/}"
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
            if file_has_markup_header "${temp_file}"; then
                log "WARN" "Remote allowlist source appears to contain HTML/XML and will be discarded: ${url}"
                rm -f "${temp_file}"
            else
                split_ip_families_from_file "${temp_file}" "${staging_v4}/${cache_name}.v4" "${staging_v6}/${cache_name}.v6" || true
                if [[ -s "${staging_v4}/${cache_name}.v4" || -s "${staging_v6}/${cache_name}.v6" ]]; then
                    had_any_valid_output=true
                else
                    log "WARN" "Remote allowlist source ${url} produced no valid IPv4/IPv6 entries."
                fi
            fi
        fi

        if [[ "${had_any_valid_output}" != true ]]; then
            if [[ -f "${ALLOW_SOURCE_DIR_V4}/${cache_name}.v4" ]]; then
                cp -f "${ALLOW_SOURCE_DIR_V4}/${cache_name}.v4" "${staging_v4}/${cache_name}.v4"
                had_cached_copy=true
            fi
            if [[ -f "${ALLOW_SOURCE_DIR_V6}/${cache_name}.v6" ]]; then
                cp -f "${ALLOW_SOURCE_DIR_V6}/${cache_name}.v6" "${staging_v6}/${cache_name}.v6"
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
                if ! resolved_output=$(dig +short "@${ns}" "${domain}" A 2>/dev/null |
                    awk '$1 ~ /^[0-9.]+$/ && !seen[$1]++ { print $1 }'); then
                    continue
                fi
            else
                if ! resolved_output=$(dig +short "@${ns}" "${domain}" AAAA 2>/dev/null |
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
# shellcheck disable=SC2310
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

        cache_base=$(domain_cache_name_from_hostname "${domain}")
        any_satisfied=false

        if [[ "${family}" == "A" || "${family}" == "BOTH" ]]; then
            if resolve_domain_family_to_file "${domain}" A "${stage_v4}/${cache_base}.v4"; then
                any_satisfied=true
            elif [[ -f "${cache_dir_v4}/${cache_base}.v4" ]]; then
                cp -f "${cache_dir_v4}/${cache_base}.v4" "${stage_v4}/${cache_base}.v4"
                log "WARN" "Using cached IPv4 entry for manual ${label} domain: ${domain}"
                any_satisfied=true
            elif [[ "${family}" == "A" ]]; then
                die "Failed to resolve required IPv4 record for manual ${label} domain '${domain}' and no cache exists."
            fi
        fi

        if [[ "${family}" == "AAAA" || "${family}" == "BOTH" ]]; then
            if resolve_domain_family_to_file "${domain}" AAAA "${stage_v6}/${cache_base}.v6"; then
                any_satisfied=true
            elif [[ -f "${cache_dir_v6}/${cache_base}.v6" ]]; then
                cp -f "${cache_dir_v6}/${cache_base}.v6" "${stage_v6}/${cache_base}.v6"
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
# shellcheck disable=SC2310
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

    if ! try_command env "GEOIP_REQUIRE_IPV6=${downloader_require_ipv6}" "${COUNTRY_IPS_DOWNLOADER}" -c "${downloader_countries_arg}"; then
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

    directory_has_files "${merged_allow_dir_v4}" || die "No IPv4 allowlist inputs available after merging generated, remote, and manual sources."

    log "INFO" "Optimizing IPv4 allow lists..."
    "${iprange_cmd_v4[@]}" @"${merged_allow_dir_v4}" >"${effective_stage_v4}"
    [[ -s "${effective_stage_v4}" ]] || die "Merged IPv4 allowlist is empty. Aborting."

    cp -f "${effective_stage_v4}" "${final_allow_dir_v4}/effective.v4"
    copy_directory_contents_if_present "${BLOCK_DOMAIN_DIR_V4}" "${final_block_dir_v4}"
    copy_directory_contents_if_present "${MANUAL_BLOCK_LIST_DIR_V4}" "${final_block_dir_v4}"
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

    if ! directory_has_files "${merged_allow_dir_v6}"; then
        log "WARN" "No IPv6 allowlist inputs available after merging generated, remote, and manual sources."
        ((nullglob_was_enabled == 1)) || shopt -u nullglob
        return
    fi

    log "INFO" "Optimizing IPv6 allow lists..."
    "${iprange_cmd_v6[@]}" -6 @"${merged_allow_dir_v6}" >"${effective_stage_v6}"
    if [[ ! -s "${effective_stage_v6}" ]]; then
        log "WARN" "Merged IPv6 allowlist is empty. IPv6 Geo-IP will not be active."
        ((nullglob_was_enabled == 1)) || shopt -u nullglob
        return
    fi

    cp -f "${effective_stage_v6}" "${final_allow_dir_v6}/effective.v6"
    copy_directory_contents_if_present "${BLOCK_DOMAIN_DIR_V6}" "${final_block_dir_v6}"
    copy_directory_contents_if_present "${MANUAL_BLOCK_LIST_DIR_V6}" "${final_block_dir_v6}"
    if directory_has_files "${final_block_dir_v6}"; then
        log "INFO" "Applying manual IPv6 blocklist veto..."
        "${iprange_cmd_v6[@]}" -6 @"${final_allow_dir_v6}" --except @"${final_block_dir_v6}" >"${IP_RANGE_FILE_V6}"
    else
        cp -f "${effective_stage_v6}" "${IP_RANGE_FILE_V6}"
    fi

    if [[ ! -s "${IP_RANGE_FILE_V6}" ]]; then
        log "WARN" "IPv6 range file ${IP_RANGE_FILE_V6} is empty. IPv6 Geo-IP will not be active."
        ((nullglob_was_enabled == 1)) || shopt -u nullglob
        return
    fi

    log "INFO" "IPv6 range list created at ${IP_RANGE_FILE_V6}"
    ((nullglob_was_enabled == 1)) || shopt -u nullglob
}

###############################################################################
#
# FIREWALL BACKEND: IPTABLES
#
###############################################################################

# Remove jump from system chain, flush and delete custom chain.
# Usage: cleanup_iptables_chain <iptables_cmd> <table> <system_chain> <custom_chain>
cleanup_iptables_chain() {
    local ipt_cmd="$1" table="$2" sys_chain="$3" custom_chain="$4"
    while ${ipt_cmd} -t "${table}" -D "${sys_chain}" -j "${custom_chain}" 2>/dev/null; do :; done
    ${ipt_cmd} -t "${table}" -F "${custom_chain}" 2>/dev/null || true
    ${ipt_cmd} -t "${table}" -X "${custom_chain}" 2>/dev/null || true
}

# Helper to create/populate an ipset (v4 or v6).
# Uses 'ipset restore' for atomic, high-performance loading.
populate_ipset() {
    local set_name="$1" range_file="$2" family="$3"
    local restore_file="${TEMP_DIR}/${set_name}.ipset.restore"

    log "INFO" "Populating ipset '${set_name}' (family: ${family})..."

    # Build the restore script atomically in a single write:
    #   'create -exist' is idempotent (skips creation if set already exists).
    #   'flush'         clears stale entries from a previous run.
    # The pre-check+flush that was here previously is redundant: 'restore'
    # with these two directives handles both the first-run and re-run cases.
    {
        echo "create ${set_name} hash:net family ${family} -exist"
        echo "flush ${set_name}"
        sed "s/^/add ${set_name} /" "${range_file}"
    } >"${restore_file}"

    ipset restore <"${restore_file}" || die "Failed to restore ipset '${set_name}'"
    log "INFO" "ipset '${set_name}' populated."
}

# Apply all firewall rules using the legacy iptables backend
# Runtime rollback is intentionally best-effort on every failure path.
# shellcheck disable=SC2310
apply_rules_iptables() {
    log "INFO" "Applying rules using iptables/ipset backend..."

    local iptables_backup_file="${TEMP_DIR}/iptables.backup"
    local ip6tables_backup_file="${TEMP_DIR}/ip6tables.backup"
    local ipset_backup_v4="${TEMP_DIR}/${ALLOW_LIST_NAME_V4}.ipset.backup"
    local ipset_backup_v6="${TEMP_DIR}/${ALLOW_LIST_NAME_V6}.ipset.backup"
    iptables-save >"${iptables_backup_file}" || die "Failed to back up current iptables rules"
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save >"${ip6tables_backup_file}" || die "Failed to back up current ip6tables rules"
    fi
    backup_ipset_state "${ALLOW_LIST_NAME_V4}" "${ipset_backup_v4}"
    if [[ "${GEOBLOCK_IPV6}" == true ]]; then
        backup_ipset_state "${ALLOW_LIST_NAME_V6}" "${ipset_backup_v6}"
    else
        : >"${ipset_backup_v6}"
    fi

    # 1. Populate IPv4 ipset
    populate_ipset "${ALLOW_LIST_NAME_V4}" "${IP_RANGE_FILE_V4}" "inet"

    # 2. Cleanup Old Rules (Mangle + Filter + NAT)
    log "INFO" "Cleaning up old iptables rules and chains..."
    cleanup_iptables_chain iptables mangle PREROUTING "${IPTABLES_CHAIN_PREFIX}"_PREROUTING
    cleanup_iptables_chain iptables filter INPUT "${IPTABLES_CHAIN_PREFIX}"_INPUT
    cleanup_iptables_chain iptables filter DOCKER-USER "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER
    cleanup_iptables_chain iptables nat POSTROUTING "${IPTABLES_CHAIN_PREFIX}"_POSTROUTING

    # 3. Apply IPv4 Rules (Atomic Restore)
    # We use *mangle for PREROUTING (Gatekeeper) and *filter for INPUT/FORWARD protection.
    local iptables_rules_file="${TEMP_DIR}/iptables.rules"
    cat >"${iptables_rules_file}" <<-EOF
*mangle
:${IPTABLES_CHAIN_PREFIX}_PREROUTING - [0:0]

# --- ${IPTABLES_CHAIN_PREFIX}_PREROUTING Chain (Gatekeeper) ---
# Equivalent to nftables 'prerouting' hook.
# Filters traffic BEFORE routing decisions.

# 1. Drop Invalid
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -m state --state INVALID -j DROP

# 2. Optimization: Accept Established/Related immediately
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -m state --state RELATED,ESTABLISHED -j ACCEPT

# 3. Critical System & Local Traffic
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -i lo -j ACCEPT
# In iptables, '+' is the wildcard (equivalent to '*' in nft/shell)
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -i docker0 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -i br+ -j ACCEPT
# WireGuard interfaces (inner traffic)
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -i wg+ -j ACCEPT

# 4. Accept Private Networks (Bypass GeoIP)
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -s 10.0.0.0/8 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -s 172.16.0.0/12 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -s 192.168.0.0/16 -j ACCEPT

# 5. Geo-IP Filter (DROP)
# Drop NEW traffic not in allowlist
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -m set ! --match-set ${ALLOW_LIST_NAME_V4} src -j DROP

# 6. Default: Accept (Pass to next table)
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING -j ACCEPT
COMMIT

*filter
:${IPTABLES_CHAIN_PREFIX}_INPUT - [0:0]
:${IPTABLES_CHAIN_PREFIX}_DOCKER_USER - [0:0]

# --- ${IPTABLES_CHAIN_PREFIX}_INPUT Chain (Host Protection) ---
# Traffic has already passed GeoIP in mangle table.

-A ${IPTABLES_CHAIN_PREFIX}_INPUT -m state --state INVALID -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -i lo -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -s 10.0.0.0/8 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -s 172.16.0.0/12 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -s 192.168.0.0/16 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -p icmp -j ACCEPT

# Trust local interfaces
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -i docker0 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -i br+ -j ACCEPT
# Trust WireGuard interfaces
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -i wg+ -j ACCEPT

# SSH Brute Force Mitigation (IPv4)
# Drop new connections from a source IP exceeding 10/second.
# Uses hashlimit (same module as IPv6) for consistency across all backends.
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -p tcp --dport ${SSH_PORT} -m hashlimit --hashlimit-name ssh_v4_limit --hashlimit-mode srcip --hashlimit-above 10/second -j LOG --log-prefix "SSH BRUTE DROP: "
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -p tcp --dport ${SSH_PORT} -m hashlimit --hashlimit-name ssh_v4_limit --hashlimit-mode srcip --hashlimit-above 10/second -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_INPUT -j ACCEPT

# --- ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER Chain (Forwarding) ---
# Protects Docker containers.
# Mirrors the 'FORWARD' chain logic in nftables.

-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -m state --state INVALID -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -m state --state RELATED,ESTABLISHED -j RETURN

# Explicitly trust Docker interfaces (using '+' wildcard)
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -i docker0 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -o docker0 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -i br+ -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -o br+ -j RETURN
# Explicitly trust WireGuard interfaces
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -i wg+ -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -o wg+ -j RETURN

# Private Nets & Loopback
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -i lo -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -s 10.0.0.0/8 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -s 172.16.0.0/12 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -s 192.168.0.0/16 -j RETURN

# Note: GeoIP dropping happened in 'mangle' table.
# If we reached here, the packet is valid or established.
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER -j RETURN
COMMIT

*nat
:${IPTABLES_CHAIN_PREFIX}_POSTROUTING - [0:0]

# --- ${IPTABLES_CHAIN_PREFIX}_POSTROUTING Chain (Masquerade) ---
EOF
    # Generate masquerade rules from constant
    for iface in "${NAT_INTERFACES[@]}"; do
        # iptables uses '+' as wildcard instead of '*'
        echo "-A ${IPTABLES_CHAIN_PREFIX}_POSTROUTING -o ${iface//\*/+} -j MASQUERADE" >>"${iptables_rules_file}"
    done
    cat >>"${iptables_rules_file}" <<-EOF
COMMIT
EOF

    # Apply Rules
    if ! iptables-restore --noflush <"${iptables_rules_file}"; then
        log "ERROR" "Failed to apply iptables rules. Restoring previous ruleset..."
        rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
        die "Failed to apply iptables rules"
    fi

    # Hook into system chains
    if ! iptables -t mangle -I PREROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}"_PREROUTING; then
        log "ERROR" "Failed to install PREROUTING hook. Restoring previous iptables ruleset..."
        rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
        die "Failed to install PREROUTING hook"
    fi
    if ! iptables -I INPUT 1 -j "${IPTABLES_CHAIN_PREFIX}"_INPUT; then
        log "ERROR" "Failed to install INPUT hook. Restoring previous iptables ruleset..."
        rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
        die "Failed to install INPUT hook"
    fi
    # DOCKER-USER is created by the Docker daemon on startup; it does not exist
    # on systems without Docker or when the daemon is stopped.
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        if ! iptables -I DOCKER-USER 1 -j "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER; then
            log "ERROR" "Failed to install DOCKER-USER hook. Restoring previous iptables ruleset..."
            rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
            die "Failed to install DOCKER-USER hook"
        fi
    else
        log "WARN" "iptables DOCKER-USER chain not found (Docker not running?). Container FORWARD protection inactive."
    fi
    if ! iptables -t nat -I POSTROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}"_POSTROUTING; then
        log "ERROR" "Failed to install POSTROUTING hook. Restoring previous iptables ruleset..."
        rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
        die "Failed to install POSTROUTING hook"
    fi

    log "INFO" "iptables (IPv4) rules applied successfully."

    # 4. Handle IPv6 (ip6tables)
    if [[ "${GEOBLOCK_IPV6}" == true ]]; then
        log "INFO" "Applying ip6tables (IPv6) rules..."
        if [[ -s "${IP_RANGE_FILE_V6}" ]]; then
            populate_ipset "${ALLOW_LIST_NAME_V6}" "${IP_RANGE_FILE_V6}" "inet6"

            # Cleanup IPv6
            log "INFO" "Cleaning up old ip6tables rules..."
            cleanup_iptables_chain ip6tables mangle PREROUTING "${IPTABLES_CHAIN_PREFIX}"_PREROUTING_V6
            cleanup_iptables_chain ip6tables filter INPUT "${IPTABLES_CHAIN_PREFIX}"_INPUT_V6
            cleanup_iptables_chain ip6tables filter DOCKER-USER "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER_V6

            local ip6tables_rules_file="${TEMP_DIR}/ip6tables.rules"
            cat >"${ip6tables_rules_file}" <<-EOF
*mangle
:${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 - [0:0]

# --- ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 (Gatekeeper) ---
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -m state --state INVALID -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -i lo -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -i docker0 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -i br+ -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -i wg+ -j ACCEPT

# Accept Private & Multicast
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -s fe80::/10 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -s fc00::/7 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -s ff00::/8 -j ACCEPT

# CRITICAL: ICMPv6 must be accepted before GeoIP
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -p icmpv6 -j ACCEPT

# Geo-IP Filter (DROP)
-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -m set ! --match-set ${ALLOW_LIST_NAME_V6} src -j DROP

-A ${IPTABLES_CHAIN_PREFIX}_PREROUTING_V6 -j ACCEPT
COMMIT

*filter
:${IPTABLES_CHAIN_PREFIX}_INPUT_V6 - [0:0]
:${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 - [0:0]

# --- ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 ---
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -m state --state INVALID -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -i lo -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -s fe80::/10 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -p icmpv6 -j ACCEPT
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -i wg+ -j ACCEPT

# SSH Rate Limit (IPv6)
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -p tcp --dport ${SSH_PORT} -m hashlimit --hashlimit-name ssh_v6_limit --hashlimit-mode srcip --hashlimit-above 10/second -j LOG --log-prefix "IP6 SSH RATE-DROP: "
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -p tcp --dport ${SSH_PORT} -m hashlimit --hashlimit-name ssh_v6_limit --hashlimit-mode srcip --hashlimit-above 10/second -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_INPUT_V6 -j ACCEPT

# --- ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 ---
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -m state --state INVALID -j DROP
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -m state --state RELATED,ESTABLISHED -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -i lo -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -i docker0 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -o docker0 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -i br+ -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -o br+ -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -i wg+ -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -o wg+ -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -s fe80::/10 -j RETURN
-A ${IPTABLES_CHAIN_PREFIX}_DOCKER_USER_V6 -j RETURN
COMMIT
EOF
            if ! ip6tables-restore --noflush <"${ip6tables_rules_file}"; then
                log "ERROR" "Failed to apply ip6tables rules. Restoring previous IPv6 ruleset..."
                rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
                die "Failed to apply ip6tables rules"
            fi

            if ! ip6tables -t mangle -I PREROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}"_PREROUTING_V6; then
                log "ERROR" "Failed to install IPv6 PREROUTING hook. Restoring previous IPv6 ruleset..."
                rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
                die "Failed to install IPv6 PREROUTING hook"
            fi
            if ! ip6tables -I INPUT 1 -j "${IPTABLES_CHAIN_PREFIX}"_INPUT_V6; then
                log "ERROR" "Failed to install IPv6 INPUT hook. Restoring previous IPv6 ruleset..."
                rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
                die "Failed to install IPv6 INPUT hook"
            fi
            if ip6tables -L DOCKER-USER >/dev/null 2>&1; then
                if ! ip6tables -I DOCKER-USER 1 -j "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER_V6; then
                    log "ERROR" "Failed to install IPv6 DOCKER-USER hook. Restoring previous IPv6 ruleset..."
                    rollback_iptables_runtime_state "${iptables_backup_file}" "${ip6tables_backup_file}" "${ipset_backup_v4}" "${ipset_backup_v6}" || true
                    die "Failed to install IPv6 DOCKER-USER hook"
                fi
            else
                log "WARN" "ip6tables DOCKER-USER chain not found (Docker not running?). IPv6 container FORWARD protection inactive."
            fi

            log "INFO" "ip6tables (IPv6) rules applied successfully."
        else
            log "WARN" "IPv6 range file is empty. Skipping IPv6 rule application."
            cleanup_iptables_chain ip6tables mangle PREROUTING "${IPTABLES_CHAIN_PREFIX}"_PREROUTING_V6
            cleanup_iptables_chain ip6tables filter INPUT "${IPTABLES_CHAIN_PREFIX}"_INPUT_V6
            cleanup_iptables_chain ip6tables filter DOCKER-USER "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER_V6
            cleanup_legacy_ipset "${ALLOW_LIST_NAME_V6}" || true
        fi
    else
        # Flush if IPv6 GeoBlocking is disabled but backend is iptables
        if command -v ip6tables &>/dev/null; then
            log "INFO" "Flushing IPv6 rules (Geo-blocking disabled)..."
            cleanup_iptables_chain ip6tables mangle PREROUTING "${IPTABLES_CHAIN_PREFIX}"_PREROUTING_V6
            cleanup_iptables_chain ip6tables filter INPUT "${IPTABLES_CHAIN_PREFIX}"_INPUT_V6
            cleanup_iptables_chain ip6tables filter DOCKER-USER "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER_V6
        fi
        cleanup_legacy_ipset "${ALLOW_LIST_NAME_V6}" || true
    fi

    # Clean up native nftables table only after the legacy backend is fully active.
    nft delete table inet "${NFT_TABLE_NAME}" 2>/dev/null || true
}

###############################################################################
#
# FIREWALL BACKEND: NFTABLES
#
###############################################################################

# Apply all firewall rules using the modern nftables backend
# Legacy cleanup is intentionally best-effort after nftables activation.
# shellcheck disable=SC2310
apply_rules_nftables() {
    log "INFO" "Applying rules using nftables (native) backend..."

    # --- Prepare sets (Stream-based approach) ---
    # We write the comma-separated elements to temp files instead of variables
    # to avoid "Argument list too long" or memory issues with massive lists.
    # This allows us to handle lists of any size (e.g., full continents).

    local v4_elements_file="${TEMP_DIR}/v4_elements.nft"
    if [[ -s "${IP_RANGE_FILE_V4}" ]]; then
        # Convert newlines to commas
        paste -s -d, "${IP_RANGE_FILE_V4}" >"${v4_elements_file}"
    else
        log "WARN" "IPv4 range file is empty. Using dummy IP."
        echo "192.0.2.1" >"${v4_elements_file}" # RFC 5737 TEST-NET-1
    fi

    local v6_elements_file="${TEMP_DIR}/v6_elements.nft"
    if [[ "${GEOBLOCK_IPV6}" == true ]]; then
        # Process Allowlist
        if [[ -s "${IP_RANGE_FILE_V6}" ]]; then
            # Filter valid IPv6 chars only (hex, colon, slash) and join
            grep -E '^[0-9a-fA-F:/]+$' "${IP_RANGE_FILE_V6}" | paste -s -d, >"${v6_elements_file}" || true
        fi
        # Ensure Allowlist is securely set before application
        if [[ ! -s "${v6_elements_file}" ]]; then
            log "WARN" "IPv6 allowlist is empty (or containing only invalid entries). Using dummy IP."
            echo "2001:db8::1" >"${v6_elements_file}" # RFC 3849 documentation prefix
        fi
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

            # Dynamic sets for SSH brute-force (v4 + v6) using meters (more efficient)
            set ssh_meter_v4 { type ipv4_addr; flags dynamic; size 65536; }
            set ssh_meter_v6 { type ipv6_addr; flags dynamic; size 65536; }
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
        local ft_devs=""
        if [[ -n "${FLOWTABLE_INTERFACES}" ]]; then
            ft_devs=$(expand_interfaces "${FLOWTABLE_INTERFACES}")
            if [[ -n "${ft_devs}" ]]; then
                log "INFO" "Enabling Flowtable (Fasttrack) on interfaces: ${ft_devs}"
                cat <<EOF
            flowtable f {
                hook ingress priority 0;
                devices = { ${ft_devs} };
            }
EOF
            else
                log "WARN" "No valid interfaces found for Flowtable (after expansion). Skipping."
            fi
        fi

        cat <<EOF
            # ========= CHAINS =========

            # --- PREROUTING Chain (Main Gatekeeper) ---
            # Filters *ALL* incoming traffic (Host + Forward) at the earliest point.
            # Priority mangle-2 (-152): runs AFTER conntrack (-200) so ct state is available,
            # but before any other mangle hooks that might interfere.
            chain GEOIP_PREROUTING {
                type filter hook prerouting priority mangle -2; policy accept;

                # 1. Accept critical system/stateful traffic immediately.
                #    'lo' is loopback (localhost).
                #    'established,related' allows return traffic for connections we initiated.
                iifname "lo" accept
                ct state established,related accept
                ct state invalid counter drop

                # 2. Accept private networks (Docker, WG, LAN) to bypass Geo-IP.
                #    This prevents locking ourselves out of local management.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept

                # 3. CRITICAL: Allow all ICMPv6 *before* geo-blocking.
                #    This is required for Neighbor Discovery (NDP) to work.
                #    Blocking this breaks IPv6 connectivity completely.
                ip6 nexthdr icmpv6 accept

                # 4. Geo-IP v4 Filter (DROP)
                #    Drop all NEW traffic that is NOT in the allowlist.
                #    We use a 'set' for O(1) performance regardless of list size.
                ip saddr != @${ALLOW_LIST_NAME_V4} limit rate 30/minute burst 10 packets log prefix "PREROUTING GEO-DROP: "
                ip saddr != @${ALLOW_LIST_NAME_V4} counter drop

                # 5. Geo-IP v6 Filter (DROP, if enabled)
EOF
        if [[ "${GEOBLOCK_IPV6}" == true ]]; then
            echo '                ip6 nexthdr != icmpv6 ip6 saddr != @'"${ALLOW_LIST_NAME_V6}"' limit rate 30/minute burst 10 packets log prefix "PREROUTING6 GEO-DROP: "'
            echo '                ip6 nexthdr != icmpv6 ip6 saddr != @'"${ALLOW_LIST_NAME_V6}"' counter drop'
        fi
        cat <<EOF
            }

            # --- FORWARD Chain (Flowtable Offload) ---
            # Handles traffic passing THROUGH the box (e.g., to Docker containers).
            chain FORWARD {
                type filter hook forward priority filter; policy accept;
EOF
        if [[ -n "${ft_devs}" ]]; then
            echo '                # Offload established TCP/UDP flows (IPv4 and IPv6) to the flowtable.'
            echo '                # meta l4proto matches both address families; ip protocol would silently skip IPv6.'
            echo '                meta l4proto { tcp, udp } flow offload @f'
        fi
        cat <<EOF

                # Optimization: Accept established/related traffic immediately.
                # This saves CPU cycles by avoiding rule evaluation for every packet in the stream.
                ct state established,related accept

                # Docker Integration: Explicitly accept traffic on Docker interfaces.
                # Although the policy is accept, explicit rules ensure traffic flow regardless
                # of future policy changes or interactions with Docker's own chains.
                # Added WireGuard (wg*) support for VPN traffic forwarding.
                iifname { "lo", "docker0" } accept
                iifname "wg*" accept
                iifname "br-*" accept
                oifname "docker0" accept
                oifname "wg*" accept
                oifname "br-*" accept
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
                #    This aligns with iptables logic and prevents LAN lockouts/rate-limiting.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept
                # Trust local interfaces and WireGuard
                iifname { "lo", "docker0" } accept
                iifname "wg*" accept
                iifname "br-*" accept

                # 4. SSH Brute Force Mitigation (v4) - Optimized with Dynamic Set
                #    If IP exceeds 10/second, it is dropped.
                tcp dport ${SSH_PORT} ct state new update @ssh_meter_v4 { ip saddr limit rate over 10/second } counter log prefix "INPUT SSH RATE-DROP: " drop

                # 5. SSH Brute Force Mitigation (v6) - Optimized with Dynamic Set
                tcp dport ${SSH_PORT} ct state new update @ssh_meter_v6 { ip6 saddr limit rate over 10/second } counter log prefix "INPUT6 SSH RATE-DROP: " drop
            }

            # --- POSTROUTING Chain (NAT) ---
            chain POSTROUTING {
                type nat hook postrouting priority srcnat; policy accept;
EOF
        # Generate masquerade rules from constant
        for iface in "${NAT_INTERFACES[@]}"; do
            echo "                oifname \"${iface}\" masquerade"
        done
        cat <<EOF
            }
        }
EOF
    ) >"${nft_config_file}"
    # Note: -o (optimize) is intentionally omitted because it conflicts with 'auto-merge'
    # and causes "File exists" errors. 'auto-merge' combined with 'iprange' already
    # ensures the sets are optimized in the kernel.

    [[ -s "${nft_config_file}" ]] || die "Generated nftables config is empty. Aborting to preserve existing rules."

    if ! nft -c -f "${nft_config_file}"; then
        die "Generated nftables config failed validation. Existing rules were left untouched."
    fi

    log "INFO" "Replacing ${NFT_TABLE_NAME} table atomically..."
    if ! nft -f "${nft_config_file}"; then
        die "nftables ruleset application failed. Existing rules were left untouched."
    fi

    # Remove legacy iptables rules only after nftables is active.
    if command -v iptables &>/dev/null; then
        log "INFO" "Cleaning up legacy iptables rules..."
        cleanup_iptables_chain iptables mangle PREROUTING "${IPTABLES_CHAIN_PREFIX}"_PREROUTING
        cleanup_iptables_chain iptables filter INPUT "${IPTABLES_CHAIN_PREFIX}"_INPUT
        cleanup_iptables_chain iptables filter DOCKER-USER "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER
        cleanup_iptables_chain iptables nat POSTROUTING "${IPTABLES_CHAIN_PREFIX}"_POSTROUTING
    fi
    if command -v ip6tables &>/dev/null; then
        log "INFO" "Cleaning up legacy ip6tables rules..."
        cleanup_iptables_chain ip6tables mangle PREROUTING "${IPTABLES_CHAIN_PREFIX}"_PREROUTING_V6
        cleanup_iptables_chain ip6tables filter INPUT "${IPTABLES_CHAIN_PREFIX}"_INPUT_V6
        cleanup_iptables_chain ip6tables filter DOCKER-USER "${IPTABLES_CHAIN_PREFIX}"_DOCKER_USER_V6
    fi
    cleanup_legacy_ipset "${ALLOW_LIST_NAME_V4}" || true
    cleanup_legacy_ipset "${ALLOW_LIST_NAME_V6}" || true

    log "INFO" "nftables ruleset applied successfully."
}

###################
# Main Logic
###################
# Blocklist download status selects online or cached operation.
# shellcheck disable=SC2310
main() {
    # Validate CLI and environment configuration before requiring root.
    parse_arguments "$@"
    if [[ "${CHECK_CONFIG}" == true ]]; then
        printf 'ip_blocker configuration is valid\n'
        return 0
    fi

    # Check root, create the secure staging directory and install traps.
    setup_temp_dir_and_traps
    log_dns_config

    # Check internet (fail-fast)
    check_connectivity

    # 4. Detect nftables vs iptables (must be *after* parse_arguments)
    detect_backend

    # 5. Check if required commands are installed
    check_installed_commands

    # 6. Create directories
    mkdir -p \
        "${ALLOW_LIST_DIR_V4}" "${ALLOW_LIST_DIR_V6}" \
        "${ALLOW_SOURCE_DIR_V4}" "${ALLOW_SOURCE_DIR_V6}" \
        "${ALLOW_DOMAIN_DIR_V4}" "${ALLOW_DOMAIN_DIR_V6}" \
        "${MANUAL_ALLOW_LIST_DIR_V4}" "${MANUAL_ALLOW_LIST_DIR_V6}" \
        "${BLOCK_LIST_DIR}" "${BLOCK_LIST_DIR_V4}" "${BLOCK_LIST_DIR_V6}" \
        "${BLOCK_DOMAIN_DIR_V4}" "${BLOCK_DOMAIN_DIR_V6}" \
        "${MANUAL_BLOCK_LIST_DIR_V4}" "${MANUAL_BLOCK_LIST_DIR_V6}" ||
        die "Failed to create directories"

    # 7. Download v4 blocklists if -b is used.
    # Non-fatal: if the remote index is unreachable (transient DNS/network issue),
    # we disable blocklists for this run and continue with geo-IP only.
    if [[ "${USE_BLOCKLIST}" == true ]]; then
        if download_blocklists; then
            separate_ip_families
        else
            log "WARN" "Blocklist download failed; proceeding with geo-IP filtering only."
            USE_BLOCKLIST=false
        fi
    fi

    # 8. Download country lists and generate final v4/v6 range files.
    # Falls back to cached lists on transient failures; dies only if no cache exists.
    generate_ip_list

    # 9. Dispatch to the correct firewall function
    if [[ "${FIREWALL_BACKEND}" == "nftables" ]]; then
        apply_rules_nftables
    elif [[ "${FIREWALL_BACKEND}" == "iptables" ]]; then
        apply_rules_iptables
    else
        die "Internal error: No valid firewall backend determined."
    fi

    log "INFO" "Configuration completed successfully."
}

# Pass all command-line arguments to the main function
main "$@"
