#!/usr/bin/env bash
set -euo pipefail
umask 077

# Monitor a certificate managed by Nginx Proxy Manager (NPM) or NPMplus and
# publish it as a PKCS#12/PFX file. Both products expose a certificate directory
# containing fullchain.pem and privkey.pem; the script intentionally depends on
# that stable file contract instead of product-specific installation paths.
#
# Configuration precedence is:
#   built-in operational defaults < environment variables < CLI arguments
#
# Deployment-specific paths have no built-in defaults. This keeps the script
# suitable for a public repository and prevents accidental use of another
# machine's configuration.

source_dir=${CERT_MONITOR_SOURCE_DIR:-}
output_file=${CERT_MONITOR_OUTPUT:-}
settle_seconds=${CERT_MONITOR_SETTLE_SECONDS:-10}
lock_file=${CERT_MONITOR_LOCK_FILE:-"${XDG_RUNTIME_DIR:-/tmp}/cert_monitor_${UID}.lock"}
output_mode=${CERT_MONITOR_OUTPUT_MODE:-0600}
password_file=${CERT_MONITOR_PASSWORD_FILE:-}
run_once=false

# Derived paths are populated only after configuration has been validated.
fullchain_file=
private_key_file=
output_dir=
output_name=

# The currently unpublished temporary PFX is tracked globally so signal and
# error exits can remove it without touching the last known-good output.
active_temp=

log() {
    local level=${1}
    shift
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "${level}" "$*" >&2
}

die() {
    log "ERROR" "$*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  cert_monitor.sh --source-dir DIR --output FILE [OPTIONS]

Required configuration:
  --source-dir DIR       Directory containing fullchain.pem and privkey.pem
  --output FILE          Absolute path of the PFX file to publish

Optional configuration:
  --settle-seconds N     Delay after a filesystem event (default: 10)
  --lock-file FILE       Lock file used to prevent concurrent instances
  --output-mode MODE     Published PFX permissions (default: 0600)
  --password-file FILE   File containing the PFX password; empty by default
  --once                 Convert once and exit without monitoring
  -h, --help             Show this help

Equivalent environment variables:
  Required:
    CERT_MONITOR_SOURCE_DIR
    CERT_MONITOR_OUTPUT
  Optional:
    CERT_MONITOR_SETTLE_SECONDS
    CERT_MONITOR_LOCK_FILE
    CERT_MONITOR_OUTPUT_MODE
    CERT_MONITOR_PASSWORD_FILE

CLI arguments override environment variables. All configured paths must be
absolute. Password contents are never accepted through CLI arguments or
environment variables; only a password file path may be provided.
EOF
}

require_option_value() {
    local option=${1}
    local value=${2-}
    [[ -n ${value} ]] || die "${option} requires a non-empty value"
}

parse_args() {
    while (($# > 0)); do
        case ${1} in
            --source-dir)
                require_option_value "${1}" "${2-}"
                source_dir=${2}
                shift 2
                ;;
            --source-dir=*)
                source_dir=${1#*=}
                shift
                ;;
            --output)
                require_option_value "${1}" "${2-}"
                output_file=${2}
                shift 2
                ;;
            --output=*)
                output_file=${1#*=}
                shift
                ;;
            --settle-seconds)
                require_option_value "${1}" "${2-}"
                settle_seconds=${2}
                shift 2
                ;;
            --settle-seconds=*)
                settle_seconds=${1#*=}
                shift
                ;;
            --lock-file)
                require_option_value "${1}" "${2-}"
                lock_file=${2}
                shift 2
                ;;
            --lock-file=*)
                lock_file=${1#*=}
                shift
                ;;
            --output-mode)
                require_option_value "${1}" "${2-}"
                output_mode=${2}
                shift 2
                ;;
            --output-mode=*)
                output_mode=${1#*=}
                shift
                ;;
            --password-file)
                require_option_value "${1}" "${2-}"
                password_file=${2}
                shift 2
                ;;
            --password-file=*)
                password_file=${1#*=}
                shift
                ;;
            --once)
                run_once=true
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die "positional arguments are not supported"
                break
                ;;
            -*)
                die "unknown option: ${1}"
                ;;
            *)
                die "unexpected positional argument: ${1}"
                ;;
        esac
    done
}

require_absolute_path() {
    local label=${1}
    local path=${2}

    [[ -n ${path} ]] || die "${label} is required"
    [[ ${path} == /* ]] || die "${label} must be an absolute path"
}

check_dependencies() {
    local -a commands=(basename chmod dirname flock mktemp mv openssl)
    local command

    if [[ ${run_once} == false ]]; then
        commands+=(inotifywait)
    fi
    if [[ -n ${NOTIFY_SOCKET-} ]]; then
        commands+=(systemd-notify)
    fi

    for command in "${commands[@]}"; do
        command -v "${command}" >/dev/null 2>&1 \
            || die "required command not found: ${command}"
    done
}

validate_config() {
    local lock_dir

    require_absolute_path "source directory" "${source_dir}"
    require_absolute_path "output file" "${output_file}"
    require_absolute_path "lock file" "${lock_file}"
    if [[ -n ${password_file} ]]; then
        require_absolute_path "password file" "${password_file}"
    fi

    [[ ${settle_seconds} =~ ^[0-9]+$ ]] \
        || die "settle seconds must be a non-negative integer"
    [[ ${output_mode} =~ ^0?[0-7]{3}$ ]] \
        || die "output mode must be a three-digit octal mode, optionally prefixed by 0"

    # Remove one trailing slash without turning the filesystem root into an
    # empty string.
    if [[ ${source_dir} != / ]]; then
        source_dir=${source_dir%/}
    fi

    fullchain_file=${source_dir}/fullchain.pem
    private_key_file=${source_dir}/privkey.pem
    output_dir=$(dirname -- "${output_file}")
    output_name=$(basename -- "${output_file}")
    lock_dir=$(dirname -- "${lock_file}")

    [[ -d ${source_dir} ]] \
        || die "source directory does not exist: ${source_dir}"
    [[ -r ${fullchain_file} ]] \
        || die "certificate is not readable: ${fullchain_file}"
    [[ -r ${private_key_file} ]] \
        || die "private key is not readable: ${private_key_file}"
    [[ -d ${output_dir} ]] \
        || die "output directory does not exist: ${output_dir}"
    [[ -w ${output_dir} ]] \
        || die "output directory is not writable: ${output_dir}"
    [[ ! -d ${output_file} ]] \
        || die "output path is a directory: ${output_file}"
    [[ -d ${lock_dir} && -w ${lock_dir} ]] \
        || die "lock directory does not exist or is not writable: ${lock_dir}"

    if [[ -n ${password_file} ]]; then
        [[ -f ${password_file} && -r ${password_file} && -s ${password_file} ]] \
            || die "password file must be a readable, non-empty regular file"
    fi
}

acquire_lock() {
    # Keep the lock file in place. Removing a locked path can create a second
    # inode and allow another process to acquire a different lock concurrently.
    exec 9>"${lock_file}"
    flock -n 9 || die "another certificate monitor instance is already running"
}

cleanup() {
    if [[ -n ${active_temp} ]]; then
        rm -f -- "${active_temp}"
    fi
}

convert_certificate() {
    local passout=pass:

    active_temp=$(mktemp "${output_dir}/.${output_name}.XXXXXX")
    if [[ -n ${password_file} ]]; then
        passout=file:${password_file}
    fi

    # OpenSSL verifies that the certificate and private key form a valid pair.
    # The destination is not replaced unless the complete PFX was generated.
    if ! openssl pkcs12 -export \
        -in "${fullchain_file}" \
        -inkey "${private_key_file}" \
        -out "${active_temp}" \
        -name "${output_name}" \
        -passin pass: \
        -passout "${passout}"; then
        log "ERROR" "failed to create PFX from the current certificate pair"
        rm -f -- "${active_temp}"
        active_temp=
        return 1
    fi

    if ! chmod "${output_mode}" "${active_temp}"; then
        log "ERROR" "failed to set permissions on the temporary PFX"
        rm -f -- "${active_temp}"
        active_temp=
        return 1
    fi

    # mktemp creates the file beside the destination, so rename(2) publishes it
    # atomically on the same filesystem.
    if ! mv -f -- "${active_temp}" "${output_file}"; then
        log "ERROR" "failed to publish PFX: ${output_file}"
        rm -f -- "${active_temp}"
        active_temp=
        return 1
    fi

    active_temp=
    log "INFO" "PFX updated successfully: ${output_file}"
}

notify_ready() {
    if [[ -n ${NOTIFY_SOCKET-} ]]; then
        systemd-notify --ready --status="Monitoring ${source_dir}"
        log "INFO" "systemd notified that the monitor is ready"
    fi
}

monitor_source() {
    local changed_file

    log "INFO" "Watching certificate directory: ${source_dir}"

    # A continuous watch avoids missing events while conversion is running.
    # Multiple renewal events may intentionally cause a second harmless
    # conversion; correctness is preferred over a fragile debounce mechanism.
    inotifywait \
        --monitor \
        --quiet \
        --event attrib \
        --event close_write \
        --event create \
        --event delete \
        --event moved_from \
        --event moved_to \
        --format '%f' \
        -- "${source_dir}" \
        | while IFS= read -r changed_file; do
            case ${changed_file} in
                fullchain.pem | privkey.pem)
                    log "INFO" "Detected certificate update: ${changed_file}"
                    sleep "${settle_seconds}"

                    # Conversion failure is non-fatal while monitoring: the
                    # last known-good PFX remains published and a later event can
                    # retry the conversion.
                    # shellcheck disable=SC2310
                    if ! convert_certificate; then
                        log "WARN" "PFX update failed; keeping the previous output"
                    fi
                    ;;
                *) ;;
            esac
        done

    die "certificate filesystem monitor stopped unexpectedly"
}

main() {
    parse_args "$@"
    check_dependencies
    validate_config
    acquire_lock

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    log "INFO" "Creating the initial PFX"
    convert_certificate
    notify_ready

    if [[ ${run_once} == true ]]; then
        log "INFO" "One-shot conversion completed"
        return 0
    fi

    monitor_source
}

main "$@"
