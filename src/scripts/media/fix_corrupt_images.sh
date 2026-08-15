#!/usr/bin/env bash

# Corrupt Image Repair
# Version: 2.0.0
# Updated: 2026-07-29
#
# Recursively validates common image formats and attempts to decode/re-encode
# damaged files with FFmpeg. Successful repairs can preserve the original as
# FILE.CORRUPT; unrepaired files can be renamed to FILE.BROKEN.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

MEDIA_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MEDIA_SCRIPT_DIR
# shellcheck source=src/scripts/media/media_common.sh
source "${MEDIA_SCRIPT_DIR}/media_common.sh"
media_initialize

KEEP_ORIGINAL="${MEDIA_KEEP_CORRUPT_ORIGINAL:-1}"
MARK_UNREPAIRABLE="${MEDIA_MARK_UNREPAIRABLE:-1}"
TEMP_DIR=""
TOTAL=0
CORRUPT=0
REPAIRED=0
FAILED=0

cleanup() {
    [[ -z "${TEMP_DIR}" ]] || rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

validate_config() {
    media_validate_boolean MEDIA_KEEP_CORRUPT_ORIGINAL "${KEEP_ORIGINAL}"
    media_validate_boolean MEDIA_MARK_UNREPAIRABLE "${MARK_UNREPAIRABLE}"
}

is_corrupt() {
    local file="$1"
    local extension="${file##*.}"

    extension="${extension,,}"
    if [[ "${extension}" == "jpg" || "${extension}" == "jpeg" ]] &&
        command -v jpeginfo >/dev/null 2>&1; then
        if jpeginfo -c "${file}" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi

    if ffmpeg -nostdin -hide_banner -v error -xerror -i "${file}" \
        -f null - >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

repair_image() {
    local file="$1"
    local extension="${file##*.}"
    local temp_file="${TEMP_DIR}/image-${RANDOM}.${extension}"
    local original_copy="${file}.CORRUPT"

    if [[ "${KEEP_ORIGINAL}" == "1" && -e "${original_copy}" ]]; then
        media_log ERROR "Cannot preserve corrupt original; destination exists: ${original_copy}"
        return 1
    fi

    media_log INFO "Attempting repair: ${file}"
    if ! ffmpeg -y -nostdin -hide_banner -v error -i "${file}" \
        -map_metadata 0 -q:v 2 "${temp_file}" >/dev/null 2>&1; then
        rm -f -- "${temp_file}"
        return 1
    fi
    if [[ ! -s "${temp_file}" ]]; then
        rm -f -- "${temp_file}"
        return 1
    fi
    # A true result means the repaired candidate is still corrupt.
    # shellcheck disable=SC2310
    if is_corrupt "${temp_file}"; then
        rm -f -- "${temp_file}"
        return 1
    fi

    touch -r "${file}" "${temp_file}"
    if [[ "${KEEP_ORIGINAL}" == "1" ]]; then
        mv -- "${file}" "${original_copy}"
    fi
    mv -- "${temp_file}" "${file}"
    media_log INFO "Repaired ${file}"
}

mark_unrepairable() {
    local file="$1"
    local broken_file="${file}.BROKEN"

    if [[ "${MARK_UNREPAIRABLE}" == "0" ]]; then
        media_log ERROR "Repair failed; original left untouched: ${file}"
        return 1
    fi
    if [[ -e "${broken_file}" ]]; then
        media_log ERROR "Repair failed and marker destination exists: ${broken_file}"
        return 1
    fi
    mv -- "${file}" "${broken_file}"
    media_log WARN "Repair failed; renamed file to ${broken_file}"
}

case "${1:-}" in
    --check-config)
        (($# == 1)) || media_die "--check-config accepts no additional arguments"
        validate_config
        printf 'fix_corrupt_images configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: fix_corrupt_images.sh DIRECTORY\n'
        exit 0
        ;;
    *) ;;
esac

(($# == 1)) || media_die "usage: fix_corrupt_images.sh DIRECTORY"
validate_config
[[ -d "$1" ]] || media_die "directory not found: $1"
for command_name in ffmpeg find; do
    media_require_command "${command_name}"
done

target_dir="$(cd -- "$1" && pwd)"
TEMP_DIR="$(media_make_temp_dir fix_corrupt_images)"
media_log INFO "Scanning ${target_dir}"
file_list="${TEMP_DIR}/files"
find "${target_dir}" -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.tiff' \
    -o -iname '*.webp' \) \
    ! -iname '*.BROKEN' ! -iname '*.CORRUPT' -print0 >"${file_list}"
while IFS= read -r -d '' image_file; do
    ((++TOTAL))
    # is_corrupt deliberately returns true when the validator rejects a file.
    # shellcheck disable=SC2310
    if ! is_corrupt "${image_file}"; then
        continue
    fi

    ((++CORRUPT))
    media_log WARN "Corrupt image detected: ${image_file}"
    # repair_image and mark_unrepairable expose expected per-file statuses.
    # shellcheck disable=SC2310
    if repair_image "${image_file}"; then
        ((++REPAIRED))
    else
        # shellcheck disable=SC2310
        mark_unrepairable "${image_file}" || true
        ((++FAILED))
    fi
done <"${file_list}"

media_log INFO "Scanned=${TOTAL}, corrupt=${CORRUPT}, repaired=${REPAIRED}, failed=${FAILED}"
((FAILED == 0)) || media_die "${FAILED} image repair(s) failed"
