#!/usr/bin/env bash

# Video-to-MP4 Converter
# Version: 2.0.0
# Updated: 2026-07-29
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

cleanup() {
    [[ -z "${TEMP_DIR}" ]] || rm -rf -- "${TEMP_DIR}"
}
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

codec_name() {
    ffprobe \
        -v error \
        -select_streams "$2" \
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

    media_log INFO "Analyzing interlacing: ${input_file}"
    idet_output="$(
        ffmpeg -nostdin -hide_banner -v info -i "${input_file}" \
            -filter:v idet -frames:v "${IDET_FRAMES}" -an -f null - 2>&1 || true
    )"
    tff="$(idet_count TFF "${idet_output}")"
    bff="$(idet_count BFF "${idet_output}")"
    progressive="$(idet_count Progressive "${idet_output}")"

    if ((10#${tff} + 10#${bff} > 10#${progressive})); then
        media_log INFO "Interlaced source detected (TFF=${tff}, BFF=${bff}, progressive=${progressive})"
        printf 'bwdif=mode=1:parity=-1:deint=1,format=yuv420p\n'
    else
        printf 'format=yuv420p\n'
    fi
}

process_video() {
    local input_file="$1"
    local output_file="${input_file%.*}.mp4"
    local video_codec audio_codec filter_chain temp_file
    local -a video_options audio_options

    if [[ -e "${output_file}" ]]; then
        media_log INFO "Skipping existing output: ${output_file}"
        return 0
    fi

    # Missing streams are expected probe outcomes and handled below.
    # shellcheck disable=SC2310
    video_codec="$(codec_name "${input_file}" v:0 || true)"
    # shellcheck disable=SC2310
    audio_codec="$(codec_name "${input_file}" a:0 || true)"
    [[ -n "${video_codec}" ]] || {
        media_log ERROR "No readable video stream: ${input_file}"
        return 1
    }

    temp_file="${TEMP_DIR}/output-${RANDOM}.mp4"
    if [[ "${video_codec}" == "h264" || "${video_codec}" == "hevc" ]]; then
        video_options=(-c:v copy)
        if [[ "${audio_codec}" == "aac" || "${audio_codec}" == "mp3" || "${audio_codec}" == "ac3" || -z "${audio_codec}" ]]; then
            audio_options=(-c:a copy)
        else
            audio_options=(-c:a aac -b:a "${AUDIO_BITRATE}")
        fi
        media_log INFO "Remuxing ${input_file} (video=${video_codec}, audio=${audio_codec:-none})"
    else
        filter_chain="$(detect_filter "${input_file}")"
        video_options=(-c:v libx264 -crf "${VIDEO_CRF}" -preset "${VIDEO_PRESET}" -tune film -vf "${filter_chain}")
        audio_options=(-c:a aac -b:a "${AUDIO_BITRATE}")
        media_log INFO "Transcoding ${input_file} (video=${video_codec}, audio=${audio_codec:-none})"
    fi

    if ! ffmpeg -nostdin -hide_banner -v error -stats -i "${input_file}" \
        -map_metadata 0 \
        "${video_options[@]}" \
        "${audio_options[@]}" \
        -movflags +faststart+use_metadata_tags \
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
    if ! codec_name "${temp_file}" v:0 >/dev/null; then
        media_log ERROR "Converted output failed validation: ${input_file}"
        rm -f -- "${temp_file}"
        return 1
    fi

    touch -r "${input_file}" "${temp_file}"
    mv -- "${temp_file}" "${output_file}"
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
for command_name in ffmpeg ffprobe find sed tail tr; do
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
