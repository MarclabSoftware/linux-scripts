#!/usr/bin/env bash

# Video-to-MP4 Converter
#
# Recursively converts configured source formats to MP4 without deleting the
# originals. H.264/HEVC video is remuxed when possible; older codecs are
# transcoded to H.264/AAC. Interlacing is detected before transcoding.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

MEDIA_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MEDIA_SCRIPT_DIR
# shellcheck source=src/scripts/media/media_common.sh
source "${MEDIA_SCRIPT_DIR}/media_common.sh"
media_initialize

SOURCE_EXTENSIONS="${MEDIA_SOURCE_EXTENSIONS:-avi wmv mmv mpg mpeg vob flv 3gp mts m2ts dv mov mkv}"
VIDEO_CRF="${MEDIA_VIDEO_CRF:-14}"
VIDEO_PRESET="${MEDIA_VIDEO_PRESET:-veryslow}"
AUDIO_BITRATE="${MEDIA_AUDIO_BITRATE:-320k}"
IDET_FRAMES="${MEDIA_IDET_FRAMES:-200}"
TEMP_DIR=""
FAILURES=0

trap cleanup EXIT

validate_config() {
    [[ -n "${SOURCE_EXTENSIONS//[[:space:]]/}" ]] ||
        media_die "MEDIA_SOURCE_EXTENSIONS must not be empty"
    if [[ ! "${VIDEO_CRF}" =~ ^[0-9]+$ ]] || ((10#${VIDEO_CRF} > 51)); then
        media_die "MEDIA_VIDEO_CRF must be an integer from 0 to 51"
    fi
    [[ -n "${VIDEO_PRESET}" && "${VIDEO_PRESET}" != *[[:space:]]* ]] ||
        media_die "MEDIA_VIDEO_PRESET must be non-empty and contain no whitespace"
    [[ "${AUDIO_BITRATE}" =~ ^[1-9][0-9]*[kKmM]?$ ]] ||
        media_die "MEDIA_AUDIO_BITRATE must be a positive FFmpeg bitrate"
    [[ "${IDET_FRAMES}" =~ ^[1-9][0-9]*$ ]] ||
        media_die "MEDIA_IDET_FRAMES must be a positive integer"
}

# Per-file errors are aggregated by the caller; every mutating step is checked.
process_video() {
    local input_file="$1"
    local output_file="${input_file%.*}.mp4"
    local temp_file
    local -a ffmpeg_options

    if [[ -e "${output_file}" || -L "${output_file}" ]]; then
        media_log INFO "Skipping existing output: ${output_file}"
        return 0
    fi

    # shellcheck disable=SC2310
    if ! media_mp4_options "${input_file}" ffmpeg_options convert; then
        media_log ERROR "Cannot prepare video conversion: ${input_file}"
        return 1
    fi
    # shellcheck disable=SC2310
    media_prepare_output "${output_file}" mp4 || return
    temp_file="${MEDIA_OUTPUT_FILE}"
    media_log INFO "Converting all streams: ${input_file}"

    if ! ffmpeg -nostdin -hide_banner -v error -stats -i "${input_file}" \
        "${ffmpeg_options[@]}" \
        "${temp_file}"; then
        media_log ERROR "FFmpeg failed: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi

    if [[ ! -s "${temp_file}" ]]; then
        media_log ERROR "Converted output is empty: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi
    # A failed output probe is an expected validation result.
    # shellcheck disable=SC2310
    if ! media_validate_streams "${input_file}" "${temp_file}"; then
        media_log ERROR "Converted output failed validation: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi

    # shellcheck disable=SC2310
    media_publish_output "${input_file}" "${output_file}" || {
        media_log ERROR "Cannot publish converted output: ${output_file}"
        return 1
    }
    media_log INFO "Created ${output_file}"
}

case "${1:-}" in
    --check-config)
        (($# == 1)) || media_die "--check-config accepts no additional arguments"
        validate_config
        printf 'convert_to_mp4 configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: convert_to_mp4.sh DIRECTORY\n'
        exit 0
        ;;
    *) ;;
esac

(($# == 1)) || media_die "usage: convert_to_mp4.sh DIRECTORY"
validate_config
[[ -d "$1" ]] || media_die "directory not found: $1"
for command_name in ffmpeg ffprobe find sed; do
    media_require_command "${command_name}"
done

target_dir="$(cd -- "$1" && pwd)"
TEMP_DIR="$(media_make_temp_dir convert_to_mp4)"
IFS=' ' read -r -a extensions <<<"${SOURCE_EXTENSIONS}"
declare -a find_args=()
for extension in "${extensions[@]}"; do
    [[ "${extension}" =~ ^[A-Za-z0-9]+$ ]] ||
        media_die "invalid source extension: ${extension}"
    ((${#find_args[@]} == 0)) || find_args+=(-o)
    find_args+=(-iname "*.${extension}")
done

media_log INFO "Scanning ${target_dir}"
file_list="${TEMP_DIR}/files"
find "${target_dir}" -type f \( "${find_args[@]}" \) -print0 >"${file_list}"
while IFS= read -r -d '' input_file; do
    # process_video returns a per-file status so one failure does not stop the scan.
    # shellcheck disable=SC2310
    process_video "${input_file}" || ((++FAILURES))
done <"${file_list}"

((FAILURES == 0)) || media_die "${FAILURES} conversion(s) failed"
media_log INFO "Conversion scan completed"
