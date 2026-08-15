#!/usr/bin/env bash

# Certbot Certificate Archive Cleaner
# Version: 2.0.0
# Updated: 2026-07-29
#
# Removes expired Certbot CSR/key files and archive versions older than the
# versions referenced by each live certificate. The script supports Certbot's
# standard archive/live layout, including installations managed by Nginx Proxy
# Manager. Deletion is disabled by default.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/npm_cleaner.env"

die() {
    printf 'npm_cleaner: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "$1" "$2" >&2
}

load_environment() {
    local env_file="${NPM_CLEANER_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] ||
        die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) ||
        die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

validate_non_negative_integer() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer"
}

remove_file() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        log DRY-RUN "Would remove: $1"
    else
        log INFO "Removing: $1"
        rm -f -- "$1"
    fi
}

clean_aged_files() {
    local directory="$1"
    local pattern="$2"
    local days="$3"
    local file
    local scan_file

    [[ -d "${directory}" ]] || return 0
    scan_file="$(mktemp "${WORK_DIR}/aged.XXXXXX")"
    find "${directory}" -type f -name "${pattern}" -mtime "+${days}" -print0 \
        >"${scan_file}" || die "cannot scan directory: ${directory}"
    while IFS= read -r -d '' file; do
        remove_file "${file}"
    done <"${scan_file}"
}

certificate_version() {
    local filename="${1##*/}"

    if [[ "${filename}" =~ ^(privkey|cert|chain|fullchain)([0-9]+)\.pem$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    else
        printf '%s\n' '-1'
    fi
}

clean_certificate_archive() {
    local live_key="$1"
    local current_target
    local current_version
    local minimum_version
    local archive_directory
    local archive_file
    local archive_version
    local scan_file

    current_target="$(readlink -f -- "${live_key}")" ||
        die "cannot resolve live certificate link: ${live_key}"
    current_version="$(certificate_version "${current_target}")"
    [[ "${current_version}" != "-1" ]] ||
        die "unexpected Certbot archive filename: ${current_target}"
    minimum_version=$((current_version - KEEP_OLD_VERSIONS))
    ((minimum_version > 0)) || return 0
    archive_directory="${current_target%/*}"
    scan_file="$(mktemp "${WORK_DIR}/archive.XXXXXX")"
    find "${archive_directory}" -maxdepth 1 -type f -name '*.pem' -print0 \
        >"${scan_file}" || die "cannot scan certificate archive: ${archive_directory}"

    while IFS= read -r -d '' archive_file; do
        archive_version="$(certificate_version "${archive_file}")"
        [[ "${archive_version}" != "-1" ]] || continue
        if ((archive_version < minimum_version)); then
            remove_file "${archive_file}"
        fi
    done <"${scan_file}"
}

main() {
    local live_key
    local scan_file

    clean_aged_files "${LETSENCRYPT_DIR}/csr" '*_csr-certbot.pem' "${KEEP_CSR_DAYS}"
    clean_aged_files "${LETSENCRYPT_DIR}/keys" '*_key-certbot.pem' "${KEEP_KEYS_DAYS}"

    [[ -d "${LETSENCRYPT_DIR}/live" ]] || return 0
    scan_file="$(mktemp "${WORK_DIR}/live.XXXXXX")"
    find "${LETSENCRYPT_DIR}/live" -mindepth 2 -maxdepth 2 \
        -type l -name 'privkey.pem' -print0 >"${scan_file}" ||
        die "cannot scan live certificates: ${LETSENCRYPT_DIR}/live"
    while IFS= read -r -d '' live_key; do
        clean_certificate_archive "${live_key}"
    done <"${scan_file}"
}

load_environment

readonly LETSENCRYPT_DIR="${NPM_CLEANER_LETSENCRYPT_DIR:-}"
readonly KEEP_OLD_VERSIONS="${NPM_CLEANER_KEEP_OLD_VERSIONS:-1}"
readonly KEEP_CSR_DAYS="${NPM_CLEANER_KEEP_CSR_DAYS:-180}"
readonly KEEP_KEYS_DAYS="${NPM_CLEANER_KEEP_KEYS_DAYS:-180}"
readonly DRY_RUN="${NPM_CLEANER_DRY_RUN:-1}"

[[ -n "${LETSENCRYPT_DIR}" ]] ||
    die "NPM_CLEANER_LETSENCRYPT_DIR is required"
[[ "${LETSENCRYPT_DIR}" == /* ]] ||
    die "NPM_CLEANER_LETSENCRYPT_DIR must be an absolute path"
validate_non_negative_integer NPM_CLEANER_KEEP_OLD_VERSIONS "${KEEP_OLD_VERSIONS}"
validate_non_negative_integer NPM_CLEANER_KEEP_CSR_DAYS "${KEEP_CSR_DAYS}"
validate_non_negative_integer NPM_CLEANER_KEEP_KEYS_DAYS "${KEEP_KEYS_DAYS}"
[[ "${DRY_RUN}" == "0" || "${DRY_RUN}" == "1" ]] ||
    die "NPM_CLEANER_DRY_RUN must be 0 or 1"

case "${1:-}" in
    --check-config)
        [[ -d "${LETSENCRYPT_DIR}" ]] ||
            die "Let's Encrypt directory does not exist: ${LETSENCRYPT_DIR}"
        printf 'npm_cleaner configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: npm_cleaner.sh [--check-config]\n'
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1" ;;
esac

[[ -d "${LETSENCRYPT_DIR}" ]] ||
    die "Let's Encrypt directory does not exist: ${LETSENCRYPT_DIR}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm_cleaner.XXXXXX")"
readonly WORK_DIR
trap 'rm -rf -- "${WORK_DIR}"' EXIT

main
log INFO "Certificate cleanup completed"
