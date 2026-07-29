#!/usr/bin/env bash

# Converted Source File Archiver
# Version: 2.0.0
# Updated: 2026-07-29
#
# Moves legacy video sources to a separate archive only when a same-name MP4
# exists beside the source. Directory structure is preserved, existing archive
# files are never overwritten, and the archive must be outside the scan tree.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

MEDIA_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MEDIA_SCRIPT_DIR
# shellcheck source=src/scripts/media/media_common.sh
source "${MEDIA_SCRIPT_DIR}/media_common.sh"
media_initialize

SOURCE_EXTENSIONS="${MEDIA_SOURCE_EXTENSIONS:-avi wmv mmv mpg mpeg vob flv 3gp mts m2ts dv mov mkv}"
DRY_RUN=0

usage() {
    printf '%s\n' \
        'Usage: archive_source_files.sh [--dry-run] SCAN_DIR ARCHIVE_DIR' \
        '       archive_source_files.sh --check-config'
}

archive_file() {
    local source_file="$1"
    local scan_root="$2"
    local archive_root="$3"
    local mp4_file="${source_file%.*}.mp4"
    local relative_path destination

    if [[ ! -f "${mp4_file}" ]]; then
        media_log WARN "Skipping source without matching MP4: ${source_file}"
        return 0
    fi

    relative_path="${source_file#"${scan_root}"/}"
    destination="${archive_root}/${relative_path}"
    if [[ -e "${destination}" ]]; then
        media_log ERROR "Archive destination already exists; source left untouched: ${destination}"
        return 0
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        media_log INFO "Would archive: ${relative_path}"
        return 0
    fi

    mkdir -p -- "$(dirname -- "${destination}")"
    mv -n -- "${source_file}" "${destination}"
    [[ ! -e "${source_file}" ]] ||
        media_die "could not move source without overwriting: ${source_file}"
    media_log INFO "Archived: ${relative_path}"
}

while (($# > 0)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --check-config)
            (($# == 1)) || media_die "--check-config accepts no additional arguments"
            [[ -n "${SOURCE_EXTENSIONS//[[:space:]]/}" ]] ||
                media_die "MEDIA_SOURCE_EXTENSIONS must not be empty"
            printf 'archive_source_files configuration is valid\n'
            exit 0
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*) media_die "unknown option: $1" ;;
        *) break ;;
    esac
    shift
done

(($# == 2)) || {
    usage >&2
    exit 2
}
media_validate_boolean DRY_RUN "${DRY_RUN}"
[[ -n "${SOURCE_EXTENSIONS//[[:space:]]/}" ]] ||
    media_die "MEDIA_SOURCE_EXTENSIONS must not be empty"

for command_name in find mktemp realpath; do
    media_require_command "${command_name}"
done

scan_dir="$(realpath -e -- "$1")"
[[ -d "${scan_dir}" ]] || media_die "scan path is not a directory: $1"
mkdir -p -- "$2"
archive_dir="$(realpath -e -- "$2")"
[[ -d "${archive_dir}" ]] || media_die "archive path is not a directory: $2"
[[ "${archive_dir}" != "${scan_dir}" && "${archive_dir}" != "${scan_dir}/"* ]] ||
    media_die "archive directory must be outside the scan directory"

IFS=' ' read -r -a extensions <<<"${SOURCE_EXTENSIONS}"
((${#extensions[@]} > 0)) || media_die "no source extensions configured"
find_args=()
for extension in "${extensions[@]}"; do
    [[ "${extension}" =~ ^[A-Za-z0-9]+$ ]] ||
        media_die "invalid source extension: ${extension}"
    ((${#find_args[@]} == 0)) || find_args+=(-o)
    find_args+=(-iname "*.${extension}")
done

media_log INFO "Scanning ${scan_dir}"
file_list="$(mktemp)"
trap 'rm -f -- "${file_list}"' EXIT
find "${scan_dir}" -type f \( "${find_args[@]}" \) -print0 >"${file_list}"
while IFS= read -r -d '' source_file; do
    archive_file "${source_file}" "${scan_dir}" "${archive_dir}"
done <"${file_list}"
media_log INFO "Archive operation completed"
