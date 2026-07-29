#!/usr/bin/env bash

# MP4 Standardizer
# Version: 2.0.0
# Updated: 2026-07-29
#
# Recursively validates MP4 files, remuxes modern codecs with fast-start
# metadata, and transcodes legacy video to H.264/AAC. Invalid files are renamed
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

cleanup() {
    [[ -z "${TEMP_DIR}" ]] || rm -rf -- "${TEMP_DIR}"
}
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

codec_name() {
    ffprobe \
        -v error \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$1" |
        tr -d '[:space:]'
}

idet_count() {
    local label="$1"
    local output="$2"
    local count

    count="$(
        sed -nE "s/.*${label}:[[:space:]]*([0-9]+).*/\\1/p" <<<"${output}" |
            tail -n 1
    )"
    printf '%s\n' "${count:-0}"
}

detect_filter() {
    local input_file="$1"
    local idet_output tff bff progressive

    idet_output="$(
        ffmpeg -nostdin -hide_banner -v info -i "${input_file}" \
            -filter:v idet -frames:v "${IDET_FRAMES}" -an -f null - 2>&1 || true
    )"
    tff="$(idet_count TFF "${idet_output}")"
    bff="$(idet_count BFF "${idet_output}")"
    progressive="$(idet_count Progressive "${idet_output}")"
    if ((10#${tff} + 10#${bff} > 10#${progressive})); then
        media_log INFO "Interlaced source detected: ${input_file}"
        printf 'bwdif=mode=1:parity=-1:deint=1,format=yuv420p\n'
    else
        printf 'format=yuv420p\n'
    fi
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
    mv -- "${input_file}" "${broken_file}"
    media_log WARN "Renamed invalid MP4 to ${broken_file}"
}

process_mp4() {
    local input_file="$1"
    local input_size video_codec filter_chain temp_file
    local -a ffmpeg_options

    input_size="$(stat -c %s -- "${input_file}")" || {
        media_log ERROR "Cannot read file size: ${input_file}"
        return 1
    }
    if ((input_size < MIN_VIDEO_BYTES)); then
        media_log ERROR "MP4 is smaller than ${MIN_VIDEO_BYTES} bytes: ${input_file}"
        mark_broken "${input_file}"
        return
    fi

    # Missing streams are expected probe outcomes and handled below.
    # shellcheck disable=SC2310
    video_codec="$(codec_name "${input_file}" || true)"
    if [[ -z "${video_codec}" ]]; then
        media_log ERROR "No readable video stream: ${input_file}"
        mark_broken "${input_file}"
        return
    fi

    if [[ "${video_codec}" == "h264" || "${video_codec}" == "hevc" || "${video_codec}" == "av1" ]]; then
        ffmpeg_options=(-c copy -map_metadata 0 -movflags +faststart+use_metadata_tags)
        media_log INFO "Remuxing modern MP4 (${video_codec}): ${input_file}"
    else
        filter_chain="$(detect_filter "${input_file}")"
        ffmpeg_options=(
            -c:v libx264
            -crf "${VIDEO_CRF}"
            -preset "${VIDEO_PRESET}"
            -tune film
            -vf "${filter_chain}"
            -c:a aac
            -b:a "${AUDIO_BITRATE}"
            -map_metadata 0
            -movflags +faststart+use_metadata_tags
        )
        media_log INFO "Transcoding legacy MP4 (${video_codec}): ${input_file}"
    fi

    temp_file="${TEMP_DIR}/output-${RANDOM}.mp4"
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
    if ! codec_name "${temp_file}" >/dev/null; then
        media_log ERROR "Standardized output failed validation: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi

    touch -r "${input_file}" "${temp_file}"
    mv -- "${temp_file}" "${input_file}"
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
for command_name in ffmpeg ffprobe find sed stat tail tr; do
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
