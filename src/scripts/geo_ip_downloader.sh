#!/usr/bin/env bash

# Universal Geo-IP List Downloader
# Version: 7.0.0
# Updated: 2026-07-29
#
# Backend utility for 'ip_blocker.sh'. Downloads, parses, and validates
# Geo-IP lists from multiple providers (ipdeny, ripe, nirsoft) using an
# advanced, per-provider country specification syntax.
#
# Core Features:
# - Multi-Provider: Supports 'ipdeny', 'ripe' (DB parsing), & 'nirsoft' (CSV).
# - Advanced Syntax: Accepts provider-specific country lists (e.g., 'ripe:IT;ipdeny:CN').
# - Parallel & Safe: Runs concurrent downloads and validates all lists to
#   remove empty or unsafe entries (e.g., 0.0.0.0/0).
# - Normalized Output: Generates standardized '.list.v4' and '.list.v6' files
#   inside 'lists/allow/generated/v4' and 'lists/allow/generated/v6'
#   respectively, ready for consumption by 'ip_blocker.sh' via iprange >=2.0
#   directory loading.
#
# Usage:
#   ./geo_ip_downloader.sh -c SYNTAX [-h]
#
# Options:
#   -c syntax   Provider/country list [Mandatory].
#               Example: 'ripe:IT,FR;ipdeny:CN,KR;nirsoft:DE'
#   -h          Display this help message.
#
# Environment:
#   DNS_SERVERS    Custom DNS servers for early-boot resolution (e.g. "8.8.8.8 1.1.1.1")
#
# Enable strict mode
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
readonly SCRIPT_DIR

load_environment() {
    local env_file="${GEOIP_ENV_FILE:-${SCRIPT_DIR}/geo_ip_downloader.env}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] || {
        printf 'geo_ip_downloader: environment file is not readable: %s\n' "${env_file}" >&2
        exit 1
    }
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) || {
        printf 'geo_ip_downloader: environment file must not be group/world writable: %s\n' "${env_file}" >&2
        exit 1
    }

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

load_environment

readonly ALLOW_ROOT_DIR="${GEOIP_ALLOW_ROOT_DIR:-${IP_BLOCKER_LIST_DIR:-${SCRIPT_DIR}/lists}/allow/generated}"
# Define the output directories for allowed lists
readonly ALLOW_DIR_V4="${ALLOW_ROOT_DIR}/v4"
readonly ALLOW_DIR_V6="${ALLOW_ROOT_DIR}/v6"
# Required commands for dependency checks (base set; provider-specific added later)
readonly REQUIRED_COMMANDS=(curl grep sed awk cut cp)
# Max concurrent download jobs for parallel processing
readonly MAX_DOWNLOAD_JOBS="${GEOIP_MAX_DOWNLOAD_JOBS:-4}"
# Maximum download retry attempts (exponential backoff: 2s, 4s, 8s...)
readonly MAX_DOWNLOAD_RETRIES="${GEOIP_MAX_DOWNLOAD_RETRIES:-5}"
# Allowed provider keys
declare -ra ALLOWED_PROVIDERS=(ipdeny ripe nirsoft)

###################
# Global Variables
###################

declare ALLOWED_COUNTRIES_SYNTAX="${GEOIP_COUNTRIES:-}" # e.g., "ripe:IT,FR;ipdeny:CN"
declare TEMP_DIR=""                                     # Used for RIPE/Nirsoft downloads
declare URL_PARSE_HOST=""
declare URL_PARSE_PORT=""
declare REQUIRE_IPV6_LISTS="${GEOIP_REQUIRE_IPV6:-true}"
declare CHECK_CONFIG=false
declare -a MISSING_EXPECTED_FILES=()
# Cache for resolved hostnames to avoid redundant 'dig' calls
declare -A RESOLVED_HOSTS_CACHE

###################
# Error Handling & Logging
###################
#
# NOTE (DRY): handle_error, log, die, and _resolve_hostname are intentionally
# duplicated from ip_blocker.sh. Per the project architecture, scripts are
# fully standalone with no shared library. Any changes here must be mirrored
# in ip_blocker.sh and vice versa.
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

# Standardized logging function.
# @param $1 Log level (e.g., INFO, WARN, ERROR)
# @param $2 Log message
log() {
    # Uses bash builtin printf '%()T' to avoid date subshell overhead
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] [PID:%d] %s\n' -1 "$1" "${BASHPID:-$$}" "$2" >&2
}
export -f log

# Log an error message and exit with a non-zero status.
# @param $* The error message to log
die() {
    log "ERROR" "$*"
    exit 1
}
export -f die

# Configures signal traps for robust cleanup and interrupt handling.
setup_signal_handlers() {
    # Handle ERR (any command failure)
    trap 'handle_error $LINENO' ERR
    # Handle SIGINT (Ctrl+C)
    trap 'log "INFO" "Received SIGINT"; exit 130' INT
    # Handle SIGTERM (kill)
    trap 'log "INFO" "Received SIGTERM"; exit 143' TERM
    # Handle EXIT (any script exit)
    trap 'cleanup' EXIT
}

# Cleans up temporary resources, primarily the temp directory.
# This function is called automatically on script EXIT.
cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
        log "INFO" "Removed temporary directory: ${TEMP_DIR}"
    fi
}

###################
# Argument Parsing
###################

# Displays the help message and exits.
print_usage() {
    local exit_code="${1:-1}"

    cat <<EOF

Usage: $0 -c PROVIDER:COUNTRIES_LIST[;PROVIDER2:LIST2...] [-h]

Description:
    Downloads and parses Geo-IP lists from specified providers.
    Generates standardized .list.v4 and .list.v6 files in the 'lists/allow/generated/v4' and 'v6' directories.

Options:
    -c syntax   Provider and country list specification. [Mandatory]
                Format: 'provider:CC,CC;provider:CC'
                
                Examples:
                  Single provider:   'ipdeny:US,CA'
                  Multiple providers: 'ripe:IT,FR;ipdeny:CN,KR;nirsoft:DE'
                  
    -C          Validate configuration without downloading lists.
    -h          Display this help message.

Providers:
    ipdeny      - Aggregated zones (IPv4 & IPv6). Good general coverage.
    ripe        - RIPE NCC Database (IPv4 & IPv6). High accuracy for Europe/Middle East.
    nirsoft     - CSV format (IPv4 only). Good alternative source.
EOF
    exit "${exit_code}"
}

# Parses command-line options using getopts.
parse_arguments() {
    OPTIND=1
    while getopts ":c:hC" opt; do
        case ${opt} in
            c) ALLOWED_COUNTRIES_SYNTAX="${OPTARG}" ;;
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

    [[ "${ALLOW_ROOT_DIR}" == /* ]] ||
        die "GEOIP_ALLOW_ROOT_DIR must be an absolute path"
    [[ "${MAX_DOWNLOAD_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
        die "GEOIP_MAX_DOWNLOAD_JOBS must be a positive integer"
    [[ "${MAX_DOWNLOAD_RETRIES}" =~ ^[1-9][0-9]*$ ]] ||
        die "GEOIP_MAX_DOWNLOAD_RETRIES must be a positive integer"
    case "${REQUIRE_IPV6_LISTS}" in
        1 | true) REQUIRE_IPV6_LISTS=true ;;
        0 | false) REQUIRE_IPV6_LISTS=false ;;
        *) die "GEOIP_REQUIRE_IPV6 must be 0, 1, true or false" ;;
    esac

    # The -c (countries) option is non-negotiable.
    if [[ -z "${ALLOWED_COUNTRIES_SYNTAX}" ]]; then
        log "ERROR" "Country/Provider syntax (-c) is mandatory."
        print_usage
    fi
}

# Normalizes and validates the provider/country syntax before any downloads start.
normalize_and_validate_country_syntax() {
    ALLOWED_COUNTRIES_SYNTAX="${ALLOWED_COUNTRIES_SYNTAX//[[:space:]]/}"
    ALLOWED_COUNTRIES_SYNTAX="${ALLOWED_COUNTRIES_SYNTAX%%;}"

    [[ -n "${ALLOWED_COUNTRIES_SYNTAX}" ]] || die "Country/Provider syntax (-c) is mandatory."

    local syntax_regex='^[A-Za-z]+:[A-Za-z]{2}(,[A-Za-z]{2})*(;[A-Za-z]+:[A-Za-z]{2}(,[A-Za-z]{2})*)*$'
    [[ "${ALLOWED_COUNTRIES_SYNTAX}" =~ ${syntax_regex} ]] ||
        die "Invalid syntax. Use 'provider:CC,CC;provider2:CC' (example: 'ripe:IT,FR;ipdeny:CN')."

    local group provider
    local -a provider_groups
    IFS=';' read -r -a provider_groups <<<"${ALLOWED_COUNTRIES_SYNTAX}"
    for group in "${provider_groups[@]}"; do
        provider="${group%%:*}"
        provider="${provider,,}"
        [[ " ${ALLOWED_PROVIDERS[*]} " == *" ${provider} "* ]] ||
            die "Invalid provider '${provider}'. Allowed: ${ALLOWED_PROVIDERS[*]}"
    done
}

###################
# Utility Functions
###################

# Verifies that all required external commands are installed.
# @param $1 (optional) Space-separated list of extra commands to check
check_dependencies() {
    local missing_commands=()
    local -a all_commands=("${REQUIRED_COMMANDS[@]}")

    # Append provider-specific commands if requested
    if [[ -n "${1:-}" ]]; then
        read -ra extra <<<"$1"
        all_commands+=("${extra[@]}")
    fi

    for cmd in "${all_commands[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing_commands+=("${cmd}")
    done

    # Specifically check if awk has the log() function, which is
    # required for the RIPE provider's CIDR calculation.
    if ! awk 'BEGIN { exit !(log(8)/log(2) == 3) }' 2>/dev/null; then
        missing_commands+=("awk (with 'log' function support)")
    fi

    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands/features: ${missing_commands[*]}"
}

normalize_runtime_flags() {
    REQUIRE_IPV6_LISTS="${REQUIRE_IPV6_LISTS,,}"
    case "${REQUIRE_IPV6_LISTS}" in
        true | false) ;;
        *)
            die "Invalid GEOIP_REQUIRE_IPV6 value '${REQUIRE_IPV6_LISTS}'. Allowed: true|false"
            ;;
    esac
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
    [[ -n "${RESOLVED_HOSTS_CACHE[${host}]:-}" ]] && {
        echo "${RESOLVED_HOSTS_CACHE[${host}]}"
        return 0
    }

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

# Centralized, robust function for downloading a file using curl.
# Includes granular retry logic with exponential backoff and custom DNS resolution.
# @param $1 The URL to download
# @param $2 The temporary output file path
# @return 0 on success, 1 on failure
download_file() {
    local url="$1"
    local temp_outfile="$2"
    local retries=0
    local -a resolve_opts=()
    local resolve_opts_str=""

    # 1. Handle custom DNS resolution if DNS_SERVERS is set (for early boot stability)
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        build_resolve_options_for_url "${url}" resolve_opts_str
        [[ -n "${resolve_opts_str}" ]] && read -ra resolve_opts <<<"${resolve_opts_str}"
    fi

    while ((retries < MAX_DOWNLOAD_RETRIES)); do
        # -sSLf: Silent, follow redirects, fail fast on server errors (4xx, 5xx)
        # --connect-timeout 10: Fail if connection is not made in 10s
        # --max-time 30: Fail if the *entire* download takes longer than 30s
        if curl -sSLf "${resolve_opts[@]}" --connect-timeout 10 --max-time 30 "${url}" -o "${temp_outfile}"; then
            return 0 # Success
        fi

        ((retries++))
        log "WARN" "Download failed for ${url}. Retry ${retries}/${MAX_DOWNLOAD_RETRIES}..."
        rm -f "${temp_outfile}"
        sleep $((2 ** retries)) # Exponential backoff: 2s, 4s, 8s...
    done

    log "ERROR" "Failed to download ${url} after ${MAX_DOWNLOAD_RETRIES} attempts."
    return 1 # Final failure
}
export -f _resolve_hostname
export -f download_file

# Validates a generated list file and returns:
#   0 => valid
#   1 => invalid / mixed / empty
#   2 => dangerous catch-all entry
# This function is a predicate and checks each fallible operation explicitly.
# shellcheck disable=SC2310
validate_generated_list_file() {
    local list_file="$1"
    local validation_rc=0

    [[ -s "${list_file}" ]] || return 1
    file_has_markup_header "${list_file}" && return 1

    if awk '
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
        BEGIN {
            dangerous_v4 = "0.0.0.0 - 255.255.255.255"
        }
        {
            sub(/\r$/, "", $0)
            sub(/[[:space:]]*[#;].*$/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 == "") next

            saw_data = 1

            if ($0 == "0.0.0.0" || $0 == "0.0.0.0/0" || $0 == "::/0" || $0 == dangerous_v4) {
                dangerous = 1
                next
            }

            if (is_valid_ipv4($0)) { valid++; next }
            if (is_valid_ipv4_range($0)) { valid++; next }
            if (is_valid_ipv6($0)) { valid++; next }

            invalid = 1
        }
        END {
            if (dangerous) exit 2
            if (!saw_data || invalid || valid == 0) exit 1
        }
    ' "${list_file}"; then
        :
    else
        validation_rc=$?
    fi

    return "${validation_rc}"
}

# Validates a generated IP list before moving it to the final destination.
# This prevents empty or dangerous (e.g., 0.0.0.0/0) lists from being used.
# @param $1 The path to the temporary, processed file
# @param $2 The final destination file path
# @param $3 A human-readable name for logging (e.g., "IPv4 (IT)")
# Validation status selects publish or rejection paths.
# shellcheck disable=SC2310
validate_and_move_generated_file() {
    local temp_file="$1"
    local final_file="$2"
    local list_name="$3"
    local validation_rc=0

    if validate_generated_list_file "${temp_file}"; then
        mv "${temp_file}" "${final_file}"
        log "INFO" "Successfully processed generated ${list_name} list."
        return
    fi
    validation_rc=$?

    case ${validation_rc} in
        2) log "ERROR" "DANGEROUS entry found in generated ${list_name} list. DISCARDING." ;;
        *) log "WARN" "Generated ${list_name} list contains invalid, empty, or mixed content. Ignoring." ;;
    esac
    rm -f "${temp_file}"
}
export -f validate_and_move_generated_file

# Validates whether a cached generated list is safe to reuse as a per-list fallback.
cached_generated_list_is_valid() {
    local cached_file="$1"
    local list_basename="$2"

    [[ -f "${cached_file}" ]] || return 1

    # Nirsoft has no IPv6 dataset by design; the empty placeholder is the valid cache.
    if [[ "${list_basename}" == *.nirsoft.list.v6 ]]; then
        [[ ! -s "${cached_file}" ]]
        return
    fi

    validate_generated_list_file "${cached_file}"
}

# Restores missing staged lists from the previous successful cache, list by list.
# If the exact old list does not exist, the caller will fail-safe before swapping.
# Cached-list validation is intentionally used as a predicate.
# shellcheck disable=SC2310
restore_missing_expected_lists() {
    local family="$1"
    shift

    local staging_dir allow_dir staging_file cached_file basename
    case "${family}" in
        v4)
            staging_dir="${STAGING_V4}"
            allow_dir="${ALLOW_DIR_V4}"
            ;;
        v6)
            staging_dir="${STAGING_V6}"
            allow_dir="${ALLOW_DIR_V6}"
            ;;
        *)
            die "Invalid list family for fallback restore: ${family}"
            ;;
    esac

    for basename in "$@"; do
        staging_file="${staging_dir}/${basename}"
        [[ -f "${staging_file}" ]] && continue

        if [[ "${basename}" == *.nirsoft.list.v6 ]]; then
            if [[ "${REQUIRE_IPV6_LISTS}" == "true" ]]; then
                MISSING_EXPECTED_FILES+=("${family}:${basename}")
            else
                : >"${staging_file}"
                log "INFO" "Created empty IPv6 placeholder for Nirsoft list: ${basename}"
            fi
            continue
        fi

        if [[ "${family}" == "v6" && "${REQUIRE_IPV6_LISTS}" != "true" ]]; then
            : >"${staging_file}"
            log "WARN" "IPv6 list unavailable but optional for this run. Using empty placeholder: ${basename}"
            continue
        fi

        cached_file="${allow_dir}/${basename}"
        if cached_generated_list_is_valid "${cached_file}" "${basename}"; then
            cp -f -- "${cached_file}" "${staging_file}" || die "Failed to restore cached list '${basename}'"
            log "WARN" "Using cached allowlist for unavailable source: ${basename}"
            continue
        fi

        MISSING_EXPECTED_FILES+=("${family}:${basename}")
    done
}

# Replaces a list directory with a fully prepared staging directory using O(1) renames.
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

# A wrapper function that downloads, cleans, and validates a simple list.
# @param $1 The URL to download
# @param $2 The final output file path
# @param $3 A human-readable name for logging
# Download status selects the logged skip path.
# shellcheck disable=SC2310
download_and_validate_simple() {
    local url="$1"
    local outfile="$2"
    local proto_name="$3" # e.g., "IPv4 (IT)"
    local temp_outfile="${outfile}.tmp"

    log "INFO" "Downloading ${proto_name} list from ${url}"

    if ! download_file "${url}" "${temp_outfile}"; then
        log "WARN" "Failed to download ${proto_name} list. Skipping."
        return
    fi

    # Normalize comment-only lines and inline annotations before persisting the file.
    awk '
        {
            sub(/\r$/, "", $0)
            sub(/[[:space:]]*[#;].*$/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 != "") print
        }
    ' "${temp_outfile}" >"${temp_outfile}.cleaned" || die "Failed to normalize ${proto_name} list"
    mv -f -- "${temp_outfile}.cleaned" "${temp_outfile}" || die "Failed to finalize normalized ${proto_name} list"

    validate_and_move_generated_file "${temp_outfile}" "${outfile}" "${proto_name}"
}
export -f download_and_validate_simple

# Helper function for parallel processing.
# Blocks execution until a free job slot (from 'jobs -p') is available.
wait_for_job_slot() {
    local -a running_jobs=()
    # '|| true' prevents 'set -e' from exiting if 'wait -n'
    # returns a non-zero status (e.g., if a job failed), allowing
    # the script to continue processing other jobs.
    while :; do
        mapfile -t running_jobs < <(jobs -pr || true)
        ((${#running_jobs[@]} < MAX_DOWNLOAD_JOBS)) && return 0
        wait -n || true
    done
}
export -f wait_for_job_slot

###################
# Provider: ipdeny
###################

# Downloads IPv4 and IPv6 lists for a single country from ipdeny.com.
# @param $1 The 2-letter uppercase country code (e.g., IT)
_download_country_ipdeny() {
    local code="$1"
    local code_lower="${code,,}"

    local V4_URL="https://www.ipdeny.com/ipblocks/data/aggregated/${code_lower}-aggregated.zone"
    local V4_OUT_FILE="${STAGING_V4}/${code_lower}.ipdeny.list.v4"
    download_and_validate_simple "${V4_URL}" "${V4_OUT_FILE}" "IPv4 (${code})"

    local V6_URL="https://www.ipdeny.com/ipv6/ipaddresses/aggregated/${code_lower}-aggregated.zone"
    local V6_OUT_FILE="${STAGING_V6}/${code_lower}.ipdeny.list.v6"
    download_and_validate_simple "${V6_URL}" "${V6_OUT_FILE}" "IPv6 (${code})"
}
export -f _download_country_ipdeny

# Main function for the 'ipdeny' provider.
# @param $@ A list of country codes (e.g., "IT" "FR" "DE")
download_provider_ipdeny() {
    local -a countries=("$@")
    log "INFO" "Using provider: ipdeny (Parallel Mode) for ${countries[*]}"
    for code in "${countries[@]}"; do
        wait_for_job_slot
        # Launch the download in the background
        _download_country_ipdeny "${code}" &
    done
    # Wait for all background jobs for this provider to complete
    wait
    log "INFO" "ipdeny download complete for ${countries[*]}"
}

###################
# Provider: ripe
###################

# Main function for the 'RIPE' provider.
# @param $@ A list of country codes (e.g., "IT" "FR" "DE")
# Provider downloads return checked status for fallback handling.
# shellcheck disable=SC2310
download_provider_ripe() {
    local -a ripe_countries=("$@")
    if [[ ${#ripe_countries[@]} -eq 0 ]]; then
        log "WARN" "RIPE provider specified but no countries listed. Skipping."
        return
    fi

    local -r RIPE_URL="https://ftp.ripe.net/pub/stats/ripencc"
    local -r RIPE_FILE="delegated-ripencc-latest"
    local ripe_data_file="${TEMP_DIR}/${RIPE_FILE}"
    local ripe_md5_file="${TEMP_DIR}/${RIPE_FILE}.md5"

    log "INFO" "Using provider: RIPE (Supports IPv4 and IPv6) for ${ripe_countries[*]}"

    # 1. Download the database and its checksum (only if not already downloaded)
    if [[ ! -f "${ripe_data_file}" ]]; then
        log "INFO" "Downloading RIPE data file..."
        if ! download_file "${RIPE_URL}/${RIPE_FILE}" "${ripe_data_file}"; then
            log "WARN" "Failed to download RIPE data file. Falling back to cached per-country lists where available."
            return
        fi
        log "INFO" "Downloading RIPE MD5 file..."
        if ! download_file "${RIPE_URL}/${RIPE_FILE}.md5" "${ripe_md5_file}"; then
            rm -f "${ripe_data_file}"
            log "WARN" "Failed to download RIPE MD5 file. Falling back to cached per-country lists where available."
            return
        fi

        # 2. Verify checksum
        log "INFO" "Verifying RIPE file checksum..."
        local expected_md5
        expected_md5=$(awk '/MD5/ {print $NF}' "${ripe_md5_file}") || {
            rm -f "${ripe_data_file}" "${ripe_md5_file}"
            log "WARN" "Failed to parse RIPE MD5 file. Falling back to cached per-country lists where available."
            return
        }
        local computed_md5 md5_output _
        if ! md5_output=$(md5sum "${ripe_data_file}"); then
            rm -f "${ripe_data_file}" "${ripe_md5_file}"
            log "WARN" "Failed to compute RIPE checksum. Falling back to cached per-country lists where available."
            return
        fi
        read -r computed_md5 _ <<<"${md5_output}"
        if [[ "${expected_md5}" != "${computed_md5}" ]]; then
            rm -f "${ripe_data_file}" "${ripe_md5_file}"
            log "WARN" "RIPE MD5 checksum mismatch. Falling back to cached per-country lists where available."
            return
        fi
        log "INFO" "Checksum OK."
    else
        log "INFO" "Using cached RIPE data file."
    fi

    # 3. Prepare for single-pass parsing
    log "INFO" "Parsing RIPE data for ${ripe_countries[*]} (Single Pass)..."

    # We construct a string mapping "COUNTRY:V4_FILE|V6_FILE" for awk
    # and prepare the temp files.
    local awk_targets=""
    local -A temp_v4_files
    local -A temp_v6_files

    for code in "${ripe_countries[@]}"; do
        local code_lower="${code,,}"

        local v4_out="${STAGING_V4}/${code_lower}.ripe.list.v4"
        local v6_out="${STAGING_V6}/${code_lower}.ripe.list.v6"
        local temp_v4="${v4_out}.tmp"
        local temp_v6="${v6_out}.tmp"

        # Ensure temp files are empty/exist
        : >"${temp_v4}"
        : >"${temp_v6}"

        temp_v4_files[${code}]="${temp_v4}"
        temp_v6_files[${code}]="${temp_v6}"

        printf -v awk_targets '%s%s\t%s\t%s\n' "${awk_targets}" "${code}" "${temp_v4}" "${temp_v6}"
    done

    export AWK_TARGETS="${awk_targets}"

    # 4. Run AWK once
    # This AWK script performs a single-pass scan of the massive RIPE database.
    # It filters entries by country and status, calculates CIDR prefixes for IPv4,
    # and writes directly to the appropriate country/protocol files.
    awk '
        BEGIN {
            # Parse the targets map passed via environment variable.
            # Format: "IT<TAB>/path/to/v4<TAB>/path/to/v6"
            split(ENVIRON["AWK_TARGETS"], targets, "\n")
            for (i in targets) {
                if (targets[i] == "") continue
                split(targets[i], parts, "\t")
                country = parts[1]
                file_map_v4[country] = parts[2]
                file_map_v6[country] = parts[3]
                # Store country in a lookup table for O(1) access
                target_countries[country] = 1
            }
            FS = "|"
        }

        # Calculates CIDR mask from a host count (IPv4 only).
        # RIPE DB gives a number of hosts (e.g., 1024), we need the prefix length (e.g., /22).
        # Formula: 32 - log2(hosts)
        function calculate_v4_cidr(hosts) {
            if (hosts == 0) return 32
            return 32 - (log(hosts)/log(2))
        }

        # Main Loop: Process each line of the RIPE DB
        # Format: registry|cc|type|start|value|date|status
        # $2 = Country Code (e.g., IT)
        # $3 = Type (ipv4, ipv6)
        # $4 = Start IP
        # $5 = Value (Host count for IPv4, Prefix length for IPv6)
        # $7 = Status (allocated, assigned)
        
        ($2 in target_countries && ($7 == "allocated" || $7 == "assigned")) {
            if ($3 == "ipv4") {
                # IPv4: Convert host count to CIDR and append to the countrys v4 file
                printf "%s/%d\n", $4, calculate_v4_cidr($5) >> file_map_v4[$2]
            }
            else if ($3 == "ipv6") {
                # IPv6: Already in CIDR format (Start/Prefix), just append
                printf "%s/%s\n", $4, $5 >> file_map_v6[$2]
            }
        }
    ' "${ripe_data_file}"

    unset AWK_TARGETS

    # 5. Validate and move all generated files
    for code in "${ripe_countries[@]}"; do
        local code_lower="${code,,}"
        local v4_out="${STAGING_V4}/${code_lower}.ripe.list.v4"
        local v6_out="${STAGING_V6}/${code_lower}.ripe.list.v6"

        # Retrieve temp files from our array
        local temp_v4="${temp_v4_files[${code}]}"
        local temp_v6="${temp_v6_files[${code}]}"

        validate_and_move_generated_file "${temp_v4}" "${v4_out}" "IPv4 (${code}, RIPE)"
        validate_and_move_generated_file "${temp_v6}" "${v6_out}" "IPv6 (${code}, RIPE)"
    done
}
###################
# Provider: nirsoft
###################

# Downloads and parses an IPv4 list for a single country from nirsoft.net.
# @param $1 The 2-letter uppercase country code (e.g., IT)
# Download status selects the logged skip path.
# shellcheck disable=SC2310
_download_country_nirsoft() {
    local code="$1"
    local code_lower="${code,,}"
    local V4_OUT_FILE="${STAGING_V4}/${code_lower}.nirsoft.list.v4"
    local V6_OUT_FILE="${STAGING_V6}/${code_lower}.nirsoft.list.v6"
    local TEMP_V4_OUT_FILE="${V4_OUT_FILE}.tmp"
    local list_name="IPv4 (${code}, Nirsoft)"
    local URL="https://www.nirsoft.net/countryip/${code_lower}.csv"
    local temp_csv_file

    temp_csv_file=$(mktemp --tmpdir="${TEMP_DIR}") || die "Failed to create temp file"

    log "INFO" "Downloading ${list_name} CSV from ${URL}"

    if ! download_file "${URL}" "${temp_csv_file}"; then
        log "WARN" "Failed to download Nirsoft CSV for ${code}. Skipping."
        rm -f "${temp_csv_file}"
        return # Exit this sub-function
    fi

    # Parse the CSV. Format: Start IP, End IP, ..., ...
    # We convert "Start IP, End IP" to "StartIP - EndIP" for iprange
    awk -F',' 'NF>4 {printf "%s - %s\n", $1, $2}' "${temp_csv_file}" >"${TEMP_V4_OUT_FILE}"
    rm -f "${temp_csv_file}" # Clean up downloaded CSV

    validate_and_move_generated_file "${TEMP_V4_OUT_FILE}" "${V4_OUT_FILE}" "${list_name}"

    # Nirsoft provides no IPv6 data.
    # We create an empty v6 file so 'ip_blocker.sh' can find it.
    touch "${V6_OUT_FILE}"
}
export -f _download_country_nirsoft

# Main function for the 'nirsoft' provider.
# @param $@ A list of country codes (e.g., "IT" "FR" "DE")
download_provider_nirsoft() {
    local -a countries=("$@")

    if [[ "${REQUIRE_IPV6_LISTS}" == "true" ]]; then
        die "Provider 'nirsoft' does not publish IPv6 country lists and cannot satisfy GEOIP_REQUIRE_IPV6=true."
    fi

    log "INFO" "Using provider: Nirsoft (Parallel Mode, IPv4 only) for ${countries[*]}"
    for code in "${countries[@]}"; do
        wait_for_job_slot
        _download_country_nirsoft "${code}" &
    done
    wait
    log "INFO" "Nirsoft parallel download complete for ${countries[*]}"
}

###################
# Main Logic
###################

# Main execution body of the script.
main() {
    # 1. Setup traps and parse arguments
    setup_signal_handlers
    parse_arguments "$@"
    normalize_and_validate_country_syntax
    normalize_runtime_flags
    if [[ "${CHECK_CONFIG}" == true ]]; then
        printf 'geo_ip_downloader configuration is valid\n'
        return 0
    fi
    log_dns_config

    # 2. Check for all required tools
    check_dependencies

    # dig is required only when DNS_SERVERS is set (early-boot DNS override)
    if [[ -n "${DNS_SERVERS:-}" ]] && ! command -v dig >/dev/null 2>&1; then
        die "DNS_SERVERS is set but 'dig' (bind-tools/dnsutils) is not installed."
    fi

    # 3. Create the output directories
    mkdir -p "${ALLOW_DIR_V4}" "${ALLOW_DIR_V6}" || die "Failed to create directories"

    # 4. Create shared temp directory and staging sub-directories
    TEMP_DIR=$(mktemp -d "${ALLOW_ROOT_DIR}/.geoip.XXXXXX") || die "Failed to create temp directory"
    readonly STAGING_V4="${TEMP_DIR}/staging_v4"
    readonly STAGING_V6="${TEMP_DIR}/staging_v6"
    mkdir -p "${STAGING_V4}" "${STAGING_V6}"

    # Export staging paths for sub-functions
    export STAGING_V4 STAGING_V6

    # 5. Prepare for fresh downloads
    log "INFO" "Preparing staging area for fresh downloads..."

    # 6. Parse the new syntax
    log "INFO" "Parsing provider/country syntax: ${ALLOWED_COUNTRIES_SYNTAX}"

    # Use an associative array to map providers to their country lists
    declare -A provider_country_map
    local -a expected_v4_files=()
    local -a expected_v6_files=()

    # Split on semicolons using parameter expansion (no subshell)
    local -a provider_groups
    IFS=';' read -ra provider_groups <<<"${ALLOWED_COUNTRIES_SYNTAX}"

    for group in "${provider_groups[@]}"; do
        [[ -n "${group}" ]] || continue # Skip empty entries

        # Split "provider:C1,C2" using parameter expansion
        local provider_name="${group%%:*}"
        provider_name="${provider_name,,}"   # lowercase
        provider_name="${provider_name// /}" # strip spaces
        local country_list_csv="${group#*:}" # everything after first colon

        # Validate provider against array
        local valid=false
        for p in "${ALLOWED_PROVIDERS[@]}"; do
            [[ "${p}" == "${provider_name}" ]] && {
                valid=true
                break
            }
        done
        if ! "${valid}"; then
            die "Invalid provider '${provider_name}' in syntax. Allowed: ${ALLOWED_PROVIDERS[*]}"
        fi

        # Sanitize country list: uppercase, remove spaces, convert comma to space
        local sanitized_countries="${country_list_csv^^}" # uppercase
        sanitized_countries="${sanitized_countries// /}"  # strip spaces
        sanitized_countries="${sanitized_countries//,/ }" # comma → space

        # Append to the map (handles a provider being listed multiple times)
        provider_country_map[${provider_name}]+="${sanitized_countries} "

    done

    # 7. Check for RIPE-specific dependencies if needed
    if [[ -n "${provider_country_map[ripe]:-}" ]]; then
        check_dependencies "md5sum"
    fi

    # 8. Dispatch to the correct provider functions
    for provider in "${!provider_country_map[@]}"; do
        local -a country_array=()
        local -A seen_countries=()
        # Deduplicate in Bash to avoid spawning sort for a tiny fixed alphabet.
        local -a raw_countries=()
        read -ra raw_countries <<<"${provider_country_map[${provider}]}"
        for code in "${raw_countries[@]}"; do
            [[ -n "${seen_countries[${code}]:-}" ]] && continue
            seen_countries[${code}]=1
            country_array+=("${code}")
        done

        [[ ${#country_array[@]} -gt 0 ]] || continue # Skip if no countries

        log "INFO" "Dispatching download for provider: ${provider} (Countries: ${country_array[*]})"

        local code_lower
        for code in "${country_array[@]}"; do
            code_lower="${code,,}"
            expected_v4_files+=("${code_lower}.${provider}.list.v4")
            expected_v6_files+=("${code_lower}.${provider}.list.v6")
        done

        case "${provider}" in
            "ipdeny")
                # Pass the country array to the function
                download_provider_ipdeny "${country_array[@]}"
                ;;
            "ripe")
                # RIPE is monolithic; it must run sequentially in the main thread.
                # Pass the country array to the function.
                download_provider_ripe "${country_array[@]}"
                ;;
            "nirsoft")
                # Pass the country array to the function
                download_provider_nirsoft "${country_array[@]}"
                ;;
            *)
                # This should be unreachable due to validation above
                die "Unknown or unsupported provider: '${provider}'"
                ;;
        esac
    done

    # 9. Final Validation and Atomic Swap
    log "INFO" "Final check for generated lists in staging..."

    MISSING_EXPECTED_FILES=()
    restore_missing_expected_lists v4 "${expected_v4_files[@]}"
    restore_missing_expected_lists v6 "${expected_v6_files[@]}"
    if ((${#MISSING_EXPECTED_FILES[@]} > 0)); then
        die "DOWNLOAD FAILED. Missing required Geo-IP list(s) with no cached fallback: ${MISSING_EXPECTED_FILES[*]}. Existing firewall rules were preserved."
    fi

    shopt -s nullglob
    local -a staged_v4=("${STAGING_V4}"/*.list.v4)
    local -a staged_v6=("${STAGING_V6}"/*.list.v6)
    shopt -u nullglob

    local file_count
    file_count=$((${#staged_v4[@]} + ${#staged_v6[@]}))

    if [[ ${file_count} -eq 0 ]]; then
        die "DOWNLOAD FAILED. No Geo-IP lists were generated (provider unreachable?). Aborting to preserve existing firewall rules (CACHE SAFE)."
    fi

    log "INFO" "Download successful (${file_count} lists). Performing atomic directory swap..."

    atomic_swap_directory "${STAGING_V4}" "${ALLOW_DIR_V4}" "${TEMP_DIR}/allow_v4.backup"
    atomic_swap_directory "${STAGING_V6}" "${ALLOW_DIR_V6}" "${TEMP_DIR}/allow_v6.backup"

    log "INFO" "All country lists updated successfully."
}

# Pass all command-line arguments to the main function
main "$@"
