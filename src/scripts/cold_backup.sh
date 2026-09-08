#!/usr/bin/env bash

# Cold Storage Backup Utility
#
# Synchronizes selected source directories to one or two removable backup
# drives identified by filesystem UUID. Host-specific UUIDs, mount points and
# source paths are loaded from cold_backup.env beside this script.
#
# Usage:
#   sudo ./cold_backup.sh [--dry-run] [--force-nvme]
#   ./cold_backup.sh --check-config
#   sudo COLD_BACKUP_ENV_FILE=/path/to/config.env ./cold_backup.sh

set -Eeuo pipefail

if [[ "${BASH_SOURCE[0]}" == "$0" && ("${1:-}" == --help || "${1:-}" == -h) ]]; then
    cat <<'HELP'
Usage: sudo ./cold_backup.sh [--force-nvme]
       ./cold_backup.sh --dry-run [-n] [--force-nvme]
       ./cold_backup.sh --check-config
Configuration: cold_backup.env beside the script, or COLD_BACKUP_ENV_FILE.
Dry run requires the intended source and destination filesystems already mounted;
it does not create directories, acquire locks, mount, unmount or sync drives.
HELP
    exit 0
fi
IFS=$'\n\t'

###################
# Global Constants
###################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/cold_backup.env"

die() {
    printf 'cold_backup: %s\n' "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${COLD_BACKUP_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || die "environment file not found: ${env_file}"
    [[ -f "${env_file}" && -r "${env_file}" ]] || die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) || die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

load_environment

readonly UUID_NVME="${COLD_BACKUP_NVME_UUID:-}"
readonly MOUNT_NVME="${COLD_BACKUP_NVME_MOUNT:-}"
readonly DEST_NVME_BULK="${COLD_BACKUP_NVME_BULK_DESTINATION:-/data/}"
readonly DEST_NVME_HOME="${COLD_BACKUP_NVME_HOME_DESTINATION:-/home/}"

readonly UUID_HDD="${COLD_BACKUP_HDD_UUID:-}"
readonly MOUNT_HDD="${COLD_BACKUP_HDD_MOUNT:-}"
readonly DEST_HDD_BULK="${COLD_BACKUP_HDD_BULK_DESTINATION:-/data/}"
readonly DEST_HDD_HOME="${COLD_BACKUP_HDD_HOME_DESTINATION:-/home/}"

# --- Source Paths ---
# CRITICAL RSYNC RULES:
# - Trailing slash (src/) = Copy CONTENTS of src into dest
# - No trailing slash (src) = Copy FOLDER src into dest (create subdir)

readonly SRC_DATA_MOUNT="${COLD_BACKUP_SOURCE_MOUNT:?COLD_BACKUP_SOURCE_MOUNT is required}"
readonly SRC_DATA_FULL="${COLD_BACKUP_HDD_DATA_SOURCE:-}"
readonly SRC_DATA_PARTIAL="${COLD_BACKUP_NVME_DATA_SOURCE:-}"
readonly SRC_HOME="${COLD_BACKUP_HOME_SOURCE:?COLD_BACKUP_HOME_SOURCE is required}"
readonly LOCK_FILE="${COLD_BACKUP_LOCK_FILE:-/run/lock/cold_backup.lock}"

# --- Dependencies ---
readonly REQUIRED_COMMANDS=(rsync findmnt blkid realpath mount umount sync flock pkill date mkdir sleep)

# --- Rsync Options ---
# -rltD: Recursive, Links, Times, Devices (NO Perms/Owner/Group for NTFS)
# --modify-window=1: Critical for EXT4 -> NTFS timestamp precision
# --numeric-ids: Don't map uid/gid values by user/group name
# --stats: Give some file-transfer stats
# --exclude: Skip Windows system folders
DRY_RUN=false
RSYNC_OPTS=(-rltDvh --info=progress2 --inplace --delete --modify-window=1 --numeric-ids --stats "--exclude=\$RECYCLE.BIN" "--exclude=System Volume Information")

# Tracks backup drives to unmount during cleanup
MOUNT_POINTS_TO_UNMOUNT=()

###################
# Error Handling & Logging
###################

# Standardized logging function
log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] [PID:%d] %s\n' "${timestamp}" "${1}" "${BASHPID}" "${2}" >&2
}

# Cleanup function to unmount drives we mounted
cleanup() {
    local saved_exit_code=$?
    local mount_point
    local unmount_status
    local attempt idx

    # Stop any remaining child before flushing and detaching our mounts.
    pkill -P "${BASHPID}" >/dev/null 2>&1 || true
    wait || true
    log "INFO" "Flushing buffers (sync)..."
    sync || saved_exit_code=1

    # Reverse order cleanup (LIFO)
    for ((idx = ${#MOUNT_POINTS_TO_UNMOUNT[@]} - 1; idx >= 0; idx--)); do
        mount_point="${MOUNT_POINTS_TO_UNMOUNT[idx]}"

        # Check if still mounted to avoid double unmount attempts
        if findmnt -M "${mount_point}" >/dev/null; then
            log "INFO" "Cleaning up: Unmounting ${mount_point}..."
            unmount_status=1
            for attempt in 1 2 3; do
                if umount "${mount_point}"; then
                    unmount_status=0
                    break
                fi
                log "WARN" "Unmount failed for ${mount_point} (attempt ${attempt}/3). Retrying..."
                sync || saved_exit_code=1
                sleep 2
            done
            if ((unmount_status != 0)); then
                log "ERROR" "Failed to unmount ${mount_point}; leaving it mounted to avoid unsafe lazy detach."
                if ((saved_exit_code == 0)); then
                    saved_exit_code=1
                fi
            fi
        fi
    done
    exit "${saved_exit_code}"
}

# Signal traps
setup_signal_handlers() {
    trap 'log "INFO" "Interrupted by user."; exit 130' INT
    trap 'log "INFO" "Terminated."; exit 143' TERM
    trap 'cleanup' EXIT
}

###################
# Utility Functions
###################

check_dependencies() {
    local missing_commands=()
    local -a commands=("${REQUIRED_COMMANDS[@]}")
    [[ "${DRY_RUN}" != true ]] || commands=(rsync findmnt blkid realpath)
    for cmd in "${commands[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing_commands+=("${cmd}")
    done
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands: ${missing_commands[*]}"
}

# Mounts a drive if it is not already mounted
# @param $1 UUID
# @param $2 Mount Point
# Called in checked contexts; each failure is returned explicitly.
ensure_mounted() {
    local uuid="${1}"
    local mount_point="${2}"
    local mount_source
    local mounted_uuid

    if findmnt --real -M "${mount_point}" >/dev/null; then
        log "INFO" "Drive (${uuid}) is already mounted at ${mount_point}."
    elif [[ "${DRY_RUN}" == true ]]; then
        log "ERROR" "Dry-run requires an already mounted drive at ${mount_point}; no mount was attempted."
        return 1
    elif mount "${mount_point}"; then
        MOUNT_POINTS_TO_UNMOUNT+=("${mount_point}")
        log "INFO" "Mount successful."
    else
        log "ERROR" "Failed to mount ${mount_point}. Check fstab."
        return 1
    fi

    if ! mounted_uuid="$(findmnt --real -n -o UUID -M "${mount_point}")"; then
        log "ERROR" "Failed to read mounted filesystem info at ${mount_point}."
        return 1
    fi
    if [[ -z "${mounted_uuid}" ]]; then
        if ! mount_source="$(findmnt --real -n -o SOURCE -M "${mount_point}")"; then
            log "ERROR" "Failed to read mounted source at ${mount_point}."
            return 1
        fi
        if [[ "${mount_source}" == UUID=* ]]; then
            mounted_uuid="${mount_source#UUID=}"
        elif ! mounted_uuid="$(blkid -s UUID -o value "${mount_source}")"; then
            log "ERROR" "Failed to read UUID from mounted source ${mount_source}."
            return 1
        fi
    fi
    if [[ -z "${mounted_uuid}" || "${mounted_uuid^^}" != "${uuid^^}" ]]; then
        log "ERROR" "Mounted filesystem at ${mount_point} has UUID '${mounted_uuid:-unknown}', expected '${uuid}'."
        return 1
    fi

    return 0
}

# Prepares a drive for backup (Mount + Write Check)
# @param $1 UUID
# @param $2 Mount Point
# @param $3 Drive Label (for logging)
# @param $4 Icon (optional, default 💾)
# Called in checked contexts; each failure is returned explicitly.
prepare_drive() {
    local uuid="${1}"
    local mount_point="${2}"
    local label="${3}"
    local icon="${4:-💾}"

    echo "---------------------------------------------------"
    log "INFO" "${icon} INITIALIZING ${label} BACKUP SEQUENCE"
    echo "---------------------------------------------------"

    # shellcheck disable=SC2310
    if ! ensure_mounted "${uuid}" "${mount_point}"; then
        log "ERROR" "Skipping ${label} backup due to mount failure."
        return 1
    fi

    if [[ "${DRY_RUN}" != true && ! -w "${mount_point}" ]]; then
        log "ERROR" "${label} mount point is read-only. Skipping."
        return 1
    fi
    return 0
}

# Wrapper for rsync execution
# @param $1 Source path
# @param $2 Destination full path
# @param $3 Description
# Called in checked contexts; each failure is returned explicitly.
run_rsync() {
    local src="${1}"
    local dest="${2}"
    local desc="${3}"

    log "INFO" ">>> Starting: ${desc}"
    log "INFO" "    Source: ${src}"
    log "INFO" "    Target: ${dest}"

    local source_path source_mount
    source_path="$(realpath -ms -- "${src}")" || return
    source_mount="$(realpath -ms -- "${SRC_DATA_MOUNT}")" || return
    if [[ "${source_path}" == "${source_mount}" || "${source_path}" == "${source_mount%/}/"* ]] &&
        ! findmnt --real -M "${SRC_DATA_MOUNT}" >/dev/null; then
        log "ERROR" "Source mount is not mounted: ${SRC_DATA_MOUNT}. Refusing rsync --delete."
        return 1
    fi
    if [[ ! -d "${src}" ]]; then
        log "ERROR" "Source directory not found: ${src}"
        return 1
    fi
    if [[ "${DRY_RUN}" != true ]] && ! mkdir -p -- "${dest}"; then
        log "ERROR" "Failed to create destination directory: ${dest}"
        return 1
    fi

    if rsync "${RSYNC_OPTS[@]}" "${src}" "${dest}"; then
        log "INFO" ">>> Success: ${desc}"
    else
        log "ERROR" ">>> FAILED: ${desc}"
        # We do not exit here to allow subsequent backups to proceed
        return 1
    fi
}

###################
# Backup Logic Blocks
###################

# Called in checked contexts; each failure is returned explicitly.
perform_nvme_backup() {
    local status=0
    # shellcheck disable=SC2310
    prepare_drive "${UUID_NVME}" "${MOUNT_NVME}" "NVMe" "🚀" || return
    # shellcheck disable=SC2310
    run_rsync "${SRC_DATA_PARTIAL}" "${MOUNT_NVME}${DEST_NVME_BULK}" "NVMe: Bulk Data" || status=1
    # shellcheck disable=SC2310
    run_rsync "${SRC_HOME}" "${MOUNT_NVME}${DEST_NVME_HOME}" "NVMe: Home Data" || status=1
    return "${status}"
}

# Called in checked contexts; each failure is returned explicitly.
perform_hdd_backup() {
    local status=0
    # shellcheck disable=SC2310
    prepare_drive "${UUID_HDD}" "${MOUNT_HDD}" "HDD" "🐢" || return
    # shellcheck disable=SC2310
    run_rsync "${SRC_DATA_FULL}" "${MOUNT_HDD}${DEST_HDD_BULK}" "HDD: Bulk Data" || status=1
    # shellcheck disable=SC2310
    run_rsync "${SRC_HOME}" "${MOUNT_HDD}${DEST_HDD_HOME}" "HDD: Home Data" || status=1
    return "${status}"
}

###################
# Main
###################

validate_configuration() {
    local path
    for path in "${SRC_DATA_MOUNT}" "${SRC_HOME}" "${LOCK_FILE}"; do
        [[ "${path}" == /* && "${path}" != *[$'\r\n']* ]] ||
            die "source and lock paths must be absolute single-line paths"
    done
    for path in "${MOUNT_NVME}" "${MOUNT_HDD}" "${SRC_DATA_PARTIAL}" "${SRC_DATA_FULL}"; do
        [[ -z "${path}" || ("${path}" == /* && "${path}" != *[$'\r\n']*) ]] ||
            die "backup mount and data paths must be absolute single-line paths"
    done
    for path in "${MOUNT_NVME}" "${MOUNT_HDD}"; do
        [[ -z "${path}" ]] && continue
        [[ "${path}" != / && "${path}" != *'/../'* && "${path}" != */.. &&
            "${path}" != *'/./'* && "${path}" != */. && "${path}" != *'//'* ]] ||
            die "backup mount must name a dedicated mount point without dot segments"
    done
    for path in "${DEST_NVME_BULK}" "${DEST_NVME_HOME}" "${DEST_HDD_BULK}" "${DEST_HDD_HOME}"; do
        [[ "${path}" == /* && "${path}" != *[$'\r\n']* &&
            "${path}" != *'/../'* && "${path}" != */.. ]] ||
            die "destination suffix must stay below its backup mount (absolute, no parent traversal)"
    done
    [[ -n "${UUID_NVME}" || -n "${UUID_HDD}" ]] ||
        die "configure at least one backup drive UUID"
    [[ -z "${UUID_NVME}" || -n "${MOUNT_NVME}" ]] ||
        die "COLD_BACKUP_NVME_MOUNT is required when the NVMe UUID is configured"
    [[ -z "${UUID_NVME}" || -n "${SRC_DATA_PARTIAL}" ]] ||
        die "COLD_BACKUP_NVME_DATA_SOURCE is required when the NVMe UUID is configured"
    [[ -z "${UUID_HDD}" || -n "${MOUNT_HDD}" ]] ||
        die "COLD_BACKUP_HDD_MOUNT is required when the HDD UUID is configured"
    [[ -z "${UUID_HDD}" || -n "${SRC_DATA_FULL}" ]] ||
        die "COLD_BACKUP_HDD_DATA_SOURCE is required when the HDD UUID is configured"
    [[ "${SRC_DATA_MOUNT}" == /* && "${SRC_HOME}" == /* ]] ||
        die "source mount and home source must be absolute paths"
    [[ -z "${SRC_DATA_FULL}" || "${SRC_DATA_FULL}" == /* ]] ||
        die "COLD_BACKUP_HDD_DATA_SOURCE must be an absolute path"
    [[ -z "${SRC_DATA_PARTIAL}" || "${SRC_DATA_PARTIAL}" == /* ]] ||
        die "COLD_BACKUP_NVME_DATA_SOURCE must be an absolute path"
    [[ "${LOCK_FILE}" == /* ]] || die "COLD_BACKUP_LOCK_FILE must be an absolute path"
}

main() {
    local force_nvme=false
    local check_config=false

    # CLI flags deliberately override behavior, while paths stay in the sidecar.
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --dry-run | -n)
                log "INFO" "DRY-RUN MODE ENABLED: No changes will be made."
                # Replace progress bar with itemize-changes (-i) for better visibility
                RSYNC_OPTS=("${RSYNC_OPTS[@]/--info=progress2/-i}")
                RSYNC_OPTS+=("--dry-run")
                DRY_RUN=true
                shift
                ;;
            --force-nvme)
                force_nvme=true
                shift
                ;;
            --check-config)
                check_config=true
                shift
                ;;
            *)
                die "Unknown argument: ${1}"
                ;;
        esac
    done

    validate_configuration
    [[ "${force_nvme}" == false || -n "${UUID_NVME}" ]] ||
        die "--force-nvme requires COLD_BACKUP_NVME_UUID"
    if [[ "${check_config}" == true ]]; then
        printf 'cold_backup configuration is valid\n'
        exit 0
    fi

    check_dependencies
    if [[ "${DRY_RUN}" != true ]]; then
        ((EUID == 0)) || die "Please run as root/sudo"
        setup_signal_handlers
        exec 200>"${LOCK_FILE}" || die "Failed to acquire lock file descriptor."
        flock -w 5 200 || die "Another instance is already running."
    fi

    echo "==================================================="
    echo "   COLD STORAGE BACKUP UTILITY"
    echo "==================================================="

    local nvme_found=false
    local hdd_found=false
    local GLOBAL_EXIT_CODE=0

    # 1. Detection Phase
    if [[ -n "${UUID_NVME}" ]] && blkid -U "${UUID_NVME}" >/dev/null 2>&1; then
        nvme_found=true
    fi
    if [[ -n "${UUID_HDD}" ]] && blkid -U "${UUID_HDD}" >/dev/null 2>&1; then
        hdd_found=true
    fi

    if [[ "${nvme_found}" == false && "${hdd_found}" == false && "${force_nvme}" == false ]]; then
        log "WARN" "No configured backup drives were detected."
        log "WARN" "Please connect a drive and retry."
        exit 1
    fi

    log "INFO" "Detection Results: NVMe=${nvme_found} | HDD=${hdd_found}"

    # 2. Execution Phase (Priority: NVMe -> HDD)

    if [[ "${nvme_found}" == true || "${force_nvme}" == true ]]; then
        if [[ "${force_nvme}" == true && "${nvme_found}" == false ]]; then
            log "WARN" "Forcing NVMe backup even though UUID detection did not find it."
        fi
        # This helper returns errors explicitly to the enclosing decision.
        # shellcheck disable=SC2310
        perform_nvme_backup || GLOBAL_EXIT_CODE=1
    fi

    if [[ "${hdd_found}" == true ]]; then
        # Logic decision: If NVMe ran, we still run HDD but warn user it might take time
        if [[ "${nvme_found}" == true ]]; then
            log "INFO" "NVMe backup finished. Proceeding to HDD backup..."
        fi
        # This helper returns errors explicitly to the enclosing decision.
        # shellcheck disable=SC2310
        perform_hdd_backup || GLOBAL_EXIT_CODE=1
    fi

    # 3. Finalization
    echo "---------------------------------------------------"

    if [[ ${GLOBAL_EXIT_CODE} -eq 0 ]]; then
        log "INFO" "All requested operations completed successfully."
    else
        log "ERROR" "Some operations failed. Check logs for details."
    fi

    exit "${GLOBAL_EXIT_CODE}"
}

# Run only when executed; tests may source the helpers with synthetic config.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
