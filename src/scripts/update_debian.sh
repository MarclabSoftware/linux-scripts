#!/usr/bin/env bash

# Debian System Maintenance
# Version: 2.0.0
# Updated: 2026-07-29
#
# Updates Debian packages and optionally creates a configuration archive,
# vacuums the journal, updates Raspberry Pi EEPROM firmware and prunes unused
# Docker data. Destructive Docker pruning is disabled by default.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/update_debian.env"

die() {
    printf 'update_debian: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "$1" "$2" >&2
}

load_environment() {
    local env_file="${SYSTEM_UPDATE_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] || die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) || die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_boolean() {
    local name="$1"
    local value="$2"
    [[ "${value}" == "0" || "${value}" == "1" ]] || die "${name} must be 0 or 1"
}

create_backup() {
    local timestamp
    local backup_file

    [[ "${BACKUP_ENABLED}" == "1" ]] || return 0
    [[ -r "${BACKUP_PATHS_FILE}" ]] || die "backup paths file is not readable: ${BACKUP_PATHS_FILE}"
    mkdir -p -- "${BACKUP_DIR}"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_file="${BACKUP_DIR}/debian-config-${timestamp}.tar.gz"

    log INFO "Creating configuration backup: ${backup_file}"
    tar \
        --create \
        --gzip \
        --file "${backup_file}" \
        --ignore-failed-read \
        --warning=no-file-changed \
        --files-from "${BACKUP_PATHS_FILE}"
    chmod 0600 -- "${backup_file}"
}

update_packages() {
    local apt_args=()

    [[ "${ASSUME_YES}" == "0" ]] || apt_args+=(--yes)
    log INFO "Refreshing package metadata"
    apt-get update
    log INFO "Upgrading installed packages"
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_args[@]}" dist-upgrade
    log INFO "Removing orphaned packages and package cache"
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_args[@]}" autoremove
    apt-get clean
}

update_raspberry_pi_eeprom() {
    [[ "${UPDATE_RPI_EEPROM}" == "1" ]] || return 0
    if ! command -v rpi-eeprom-update >/dev/null 2>&1; then
        log WARN "rpi-eeprom-update is unavailable; skipping EEPROM update"
        return 0
    fi
    log INFO "Applying available Raspberry Pi EEPROM updates"
    rpi-eeprom-update -a
}

vacuum_journal() {
    [[ -n "${JOURNAL_RETENTION}" ]] || return 0
    log INFO "Vacuuming journal entries older than ${JOURNAL_RETENTION}"
    journalctl --vacuum-time="${JOURNAL_RETENTION}"
}

prune_docker() {
    [[ "${DOCKER_PRUNE}" == "1" ]] || return 0
    require_command docker

    log WARN "Pruning unused Docker containers, networks, images and build cache"
    docker system prune --all --force
    if [[ "${DOCKER_PRUNE_VOLUMES}" == "1" ]]; then
        log WARN "Pruning unused Docker volumes"
        docker volume prune --force
    fi
}

load_environment

readonly BACKUP_ENABLED="${SYSTEM_UPDATE_BACKUP_ENABLED:-0}"
readonly BACKUP_DIR="${SYSTEM_UPDATE_BACKUP_DIR:-/var/backups/system-maintenance}"
readonly BACKUP_PATHS_FILE="${SYSTEM_UPDATE_BACKUP_PATHS_FILE:-${SCRIPT_DIR}/update_debian.paths}"
readonly ASSUME_YES="${SYSTEM_UPDATE_ASSUME_YES:-1}"
readonly UPDATE_RPI_EEPROM="${SYSTEM_UPDATE_RPI_EEPROM:-0}"
readonly JOURNAL_RETENTION="${SYSTEM_UPDATE_JOURNAL_RETENTION:-}"
readonly DOCKER_PRUNE="${SYSTEM_UPDATE_DOCKER_PRUNE:-0}"
readonly DOCKER_PRUNE_VOLUMES="${SYSTEM_UPDATE_DOCKER_PRUNE_VOLUMES:-0}"
readonly LOCK_FILE="${SYSTEM_UPDATE_LOCK_FILE:-/run/lock/update_debian.lock}"

for boolean_name in BACKUP_ENABLED ASSUME_YES UPDATE_RPI_EEPROM DOCKER_PRUNE DOCKER_PRUNE_VOLUMES; do
    validate_boolean "${boolean_name}" "${!boolean_name}"
done
[[ "${BACKUP_DIR}" == /* && "${BACKUP_PATHS_FILE}" == /* && "${LOCK_FILE}" == /* ]] ||
    die "backup directory, paths file and lock file must be absolute paths"
[[ "${DOCKER_PRUNE}" == "1" || "${DOCKER_PRUNE_VOLUMES}" == "0" ]] ||
    die "volume pruning requires SYSTEM_UPDATE_DOCKER_PRUNE=1"

check_config=false
skip_backup=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-config) check_config=true ;;
        --skip-backup) skip_backup=true ;;
        --help | -h)
            printf 'Usage: update_debian.sh [--check-config] [--skip-backup]\n'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

if [[ "${check_config}" == "true" ]]; then
    [[ "${BACKUP_ENABLED}" == "0" || -r "${BACKUP_PATHS_FILE}" ]] ||
        die "backup paths file is not readable: ${BACKUP_PATHS_FILE}"
    printf 'update_debian configuration is valid\n'
    exit 0
fi

((EUID == 0)) || die "run this script as root"
require_command apt-get
require_command flock
require_command tar

exec 9>"${LOCK_FILE}"
flock -n 9 || die "another Debian maintenance process is already running"

df -h /
if [[ "${skip_backup}" == "false" ]]; then
    create_backup
fi
update_packages
update_raspberry_pi_eeprom
vacuum_journal
prune_docker
df -h /

if [[ -e /run/reboot-required ]]; then
    log WARN "A reboot is required"
fi
log INFO "Debian system maintenance completed"
