#!/usr/bin/env bash

# MP4 Standardizer
#
# Recursively validates MP4 files, remuxes modern codecs with fast-start
# metadata, and transcodes legacy video to H.264 while copying audio/subtitles.
# Invalid files are renamed
# to .BROKEN without overwriting an existing diagnostic copy.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

MEDIA_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MEDIA_SCRIPT_DIR
# shellcheck source=src/scripts/media/media_common.sh
source "${MEDIA_SCRIPT_DIR}/media_common.sh"
media_initialize

VIDEO_CRF="${MEDIA_VIDEO_CRF:-14}"
VIDEO_PRESET="${MEDIA_VIDEO_PRESET:-veryslow}"
AUDIO_BITRATE="${MEDIA_AUDIO_BITRATE:-320k}"
IDET_FRAMES="${MEDIA_IDET_FRAMES:-200}"
MIN_VIDEO_BYTES="${MEDIA_MIN_VIDEO_BYTES:-10000}"
MARK_BROKEN="${MEDIA_MARK_UNREPAIRABLE:-1}"
TEMP_DIR=""
FAILURES=0

trap cleanup EXIT

validate_config() {
    if [[ ! "${VIDEO_CRF}" =~ ^[0-9]+$ ]] || ((10#${VIDEO_CRF} > 51)); then
        media_die "MEDIA_VIDEO_CRF must be an integer from 0 to 51"
    fi
    [[ -n "${VIDEO_PRESET}" && "${VIDEO_PRESET}" != *[[:space:]]* ]] ||
        media_die "MEDIA_VIDEO_PRESET must be non-empty and contain no whitespace"
    [[ "${AUDIO_BITRATE}" =~ ^[1-9][0-9]*[kKmM]?$ ]] ||
        media_die "MEDIA_AUDIO_BITRATE must be a positive FFmpeg bitrate"
    [[ "${IDET_FRAMES}" =~ ^[1-9][0-9]*$ ]] ||
        media_die "MEDIA_IDET_FRAMES must be a positive integer"
    [[ "${MIN_VIDEO_BYTES}" =~ ^[1-9][0-9]*$ ]] ||
        media_die "MEDIA_MIN_VIDEO_BYTES must be a positive integer"
    media_validate_boolean MEDIA_MARK_UNREPAIRABLE "${MARK_BROKEN}"
}

mark_broken() {
    local input_file="$1"
    local broken_file="${input_file}.BROKEN"

    if [[ "${MARK_BROKEN}" == "0" ]]; then
        media_log ERROR "Invalid MP4 left untouched: ${input_file}"
        return 1
    fi
    if [[ -e "${broken_file}" ]]; then
        media_log ERROR "Cannot mark invalid MP4; destination exists: ${broken_file}"
        return 1
    fi
    mv -nT -- "${input_file}" "${broken_file}" || return
    [[ ! -e "${input_file}" ]] || return 1
    media_log WARN "Renamed invalid MP4 to ${broken_file}"
}

# Per-file errors are aggregated by the caller; every mutating step is checked.
process_mp4() {
    local input_file="$1"
    local input_size video_codec temp_file
    local -a ffmpeg_options

    input_size="$(stat -c %s -- "${input_file}")" || {
        media_log ERROR "Cannot read file size: ${input_file}"
        return 1
    }
    if ((input_size < MIN_VIDEO_BYTES)); then
        media_log ERROR "MP4 is smaller than ${MIN_VIDEO_BYTES} bytes: ${input_file}"
        mark_broken "${input_file}"
        return 1
    fi

    # Missing streams are expected probe outcomes and handled below.
    # shellcheck disable=SC2310
    video_codec="$(codec_name "${input_file}" || true)"
    if [[ -z "${video_codec}" ]]; then
        media_log ERROR "No readable video stream: ${input_file}"
        mark_broken "${input_file}"
        return 1
    fi

    # shellcheck disable=SC2310
    media_mp4_options "${input_file}" ffmpeg_options standardize || return
    media_log INFO "Standardizing all MP4 streams: ${input_file}"

    # shellcheck disable=SC2310
    media_prepare_output "${input_file}" mp4 || return
    temp_file="${MEDIA_OUTPUT_FILE}"
    if ! ffmpeg -nostdin -hide_banner -v error -stats -i "${input_file}" \
        "${ffmpeg_options[@]}" "${temp_file}"; then
        media_log ERROR "FFmpeg failed; original left untouched: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi
    if [[ ! -s "${temp_file}" ]]; then
        media_log ERROR "Standardized output is empty: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi
    # A failed output probe is an expected validation result.
    # shellcheck disable=SC2310
    if ! media_validate_streams "${input_file}" "${temp_file}"; then
        media_log ERROR "Standardized output failed validation: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi

    # shellcheck disable=SC2310
    media_publish_output "${input_file}" "${input_file}" || {
        media_log ERROR "Cannot publish standardized output: ${input_file}"
        return 1
    }
    media_log INFO "Updated ${input_file}"
}

case "${1:-}" in
    --check-config)
        (($# == 1)) || media_die "--check-config accepts no additional arguments"
        validate_config
        printf 'standardize_mp4 configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: standardize_mp4.sh DIRECTORY\n'
        exit 0
        ;;
    *) ;;
esac

(($# == 1)) || media_die "usage: standardize_mp4.sh DIRECTORY"
validate_config
[[ -d "$1" ]] || media_die "directory not found: $1"
for command_name in ffmpeg ffprobe find sed stat; do
    media_require_command "${command_name}"
done

target_dir="$(cd -- "$1" && pwd)"
TEMP_DIR="$(media_make_temp_dir standardize_mp4)"
media_log INFO "Scanning ${target_dir}"
file_list="${TEMP_DIR}/files"
find "${target_dir}" -type f -iname '*.mp4' ! -iname '*.BROKEN' -print0 >"${file_list}"
while IFS= read -r -d '' input_file; do
    # Continue the scan after a per-file failure and report a non-zero summary.
    # shellcheck disable=SC2310
    process_mp4 "${input_file}" || ((++FAILURES))
done <"${file_list}"

((FAILURES == 0)) || media_die "${FAILURES} MP4 operation(s) failed"
media_log INFO "MP4 standardization completed"
