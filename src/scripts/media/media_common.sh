#!/usr/bin/env bash

# Shared Media Script Helpers
#
# Small shared primitives for the media maintenance scripts: trusted sidecar
# loading, consistent logging, dependency checks and collision-free temporary
# directories, per-stream conversion and verified output publication.
# Source beside the media entry points; do not execute this library directly.

media_die() {
    printf 'media: %s\n' "$*" >&2
    exit 1
}

media_load_environment() {
    local env_file="${MEDIA_ENV_FILE:-${MEDIA_SCRIPT_DIR}/media_tools.env}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] ||
        media_die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) ||
        media_die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

media_initialize() {
    media_load_environment

    MEDIA_LOG_FILE="${MEDIA_LOG_FILE:-}"
    MEDIA_TEMP_ROOT="${MEDIA_TEMP_ROOT:-${TMPDIR:-/tmp}}"
    [[ -z "${MEDIA_LOG_FILE}" || "${MEDIA_LOG_FILE}" == /* ]] ||
        media_die "MEDIA_LOG_FILE must be empty or an absolute path"
    [[ "${MEDIA_TEMP_ROOT}" == /* ]] ||
        media_die "MEDIA_TEMP_ROOT must be an absolute path"

}

media_log() {
    local level="$1"
    shift
    local message
    message="$(printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s' -1 "${level}" "$*")"
    printf '%s\n' "${message}" >&2
    if [[ -n "${MEDIA_LOG_FILE}" ]]; then
        [[ -d "${MEDIA_LOG_FILE%/*}/" ]] || mkdir -p -- "${MEDIA_LOG_FILE%/*}/" || return
        printf '%s\n' "${message}" >>"${MEDIA_LOG_FILE}"
    fi
}

media_require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        media_die "required command not found: $1"
}

media_make_temp_dir() {
    local prefix="$1"
    mkdir -p -- "${MEDIA_TEMP_ROOT}" || return
    mktemp -d -- "${MEDIA_TEMP_ROOT%/}/${prefix}.XXXXXX"
}

# Probes preserve one result per stream. Selectors default to the first video.
codec_name() {
    ffprobe -v error -select_streams "${2:-v:0}" \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$1"
}

idet_count() {
    local label="$1" output="$2" count
    count="$(sed -nE "s/.*${label}:[[:space:]]*([0-9]+).*/\\1/p" <<<"${output}")" || return
    count="${count##*$'\n'}"
    printf '%s\n' "${count:-0}"
}

# A failed analysis is not evidence that a source is progressive.
# The caller validates IDET_FRAMES before processing files.
detect_filter() {
    local input_file="$1" video_index="${2:-0}"
    local idet_output tff bff progressive

    # shellcheck disable=SC2154
    idet_output="$(ffmpeg -nostdin -hide_banner -v info -i "${input_file}" \
        -map "0:v:${video_index}" -filter:v idet -frames:v "${IDET_FRAMES}" \
        -an -sn -dn -f null - 2>&1)" || {
        media_log ERROR "Cannot analyze video stream ${video_index}: ${input_file}"
        return 1
    }
    tff="$(idet_count TFF "${idet_output}")" || return
    bff="$(idet_count BFF "${idet_output}")" || return
    progressive="$(idet_count Progressive "${idet_output}")" || return
    if ((10#${tff} + 10#${bff} > 10#${progressive})); then
        media_log INFO "Interlaced video stream ${video_index}: ${input_file}"
        printf 'bwdif=mode=1:parity=-1:deint=1,format=yuv420p\n'
    else
        printf 'format=yuv420p\n'
    fi
}

# Preserve every stream. Unsupported MP4 streams fail the conversion instead
# of disappearing silently; text subtitles are converted to MP4 timed text.
# The caller validates VIDEO_CRF, VIDEO_PRESET and AUDIO_BITRATE.
media_mp4_options() {
    local input_file="$1" mode="$3" codecs codec filter_chain index
    local -n output_options="$2"

    output_options=(-map 0 -c copy -map_metadata 0 -map_chapters 0 -movflags +faststart+use_metadata_tags)
    codecs="$(codec_name "${input_file}" v)" || return
    [[ -n "${codecs}" ]] || return 1
    index=0
    while IFS= read -r codec; do
        case "${codec}" in
            h264 | hevc | av1) ;;
            *)
                filter_chain="$(detect_filter "${input_file}" "${index}")" || return
                # shellcheck disable=SC2154
                output_options+=(-c:v:"${index}" libx264 -crf:v:"${index}" "${VIDEO_CRF}"
                    -preset:v:"${index}" "${VIDEO_PRESET}" -tune:v:"${index}" film
                    -filter:v:"${index}" "${filter_chain}")
                ;;
        esac
        ((index += 1))
    done <<<"${codecs}"

    # Existing MP4 audio/subtitles already have a valid container encoding.
    [[ "${mode}" != standardize ]] || return 0
    codecs="$(codec_name "${input_file}" a)" || return
    index=0
    while IFS= read -r codec; do
        # shellcheck disable=SC2154
        case "${codec}" in
            '' | aac | mp3 | ac3) ;;
            *) output_options+=(-c:a:"${index}" aac -b:a:"${index}" "${AUDIO_BITRATE}") ;;
        esac
        ((index += 1))
    done <<<"${codecs}"
    codecs="$(codec_name "${input_file}" s)" || return
    index=0
    while IFS= read -r codec; do
        case "${codec}" in
            subrip | ass | ssa | webvtt | text)
                output_options+=(-c:s:"${index}" mov_text)
                ;;
            *) ;;
        esac
        ((index += 1))
    done <<<"${codecs}"
}

# Keep at least the original number of streams of each type. MP4 muxing may
# add a chapter-data stream, so extra output metadata streams are acceptable.
media_validate_streams() {
    local input_types output_types stream_type
    local -A remaining=()
    input_types="$(ffprobe -v error -show_entries stream=codec_type \
        -of default=noprint_wrappers=1:nokey=1 "$1")" || return
    output_types="$(ffprobe -v error -show_entries stream=codec_type \
        -of default=noprint_wrappers=1:nokey=1 "$2")" || return
    [[ -n "${input_types}" && -n "${output_types}" ]] || return 1
    while IFS= read -r stream_type; do
        remaining["${stream_type}"]=$((${remaining["${stream_type}"]:-0} + 1))
    done <<<"${input_types}"
    while IFS= read -r stream_type; do
        remaining["${stream_type}"]=$((${remaining["${stream_type}"]:-0} - 1))
    done <<<"${output_types}"
    for stream_type in "${!remaining[@]}"; do
        ((remaining["${stream_type}"] <= 0)) || return 1
    done
}

media_discard_output() {
    [[ -z "${MEDIA_OUTPUT_DIR:-}" ]] || rm -rf -- "${MEDIA_OUTPUT_DIR}" || return
    MEDIA_OUTPUT_DIR=""
    MEDIA_OUTPUT_FILE=""
}

# Create the final candidate beside its destination, never across filesystems.
# Globals let the EXIT trap clean up even after interruption during FFmpeg.
media_prepare_output() {
    media_discard_output || return
    MEDIA_OUTPUT_DIR="$(mktemp -d -- "${1%/*}/.media-output.XXXXXX")" || return
    MEDIA_OUTPUT_FILE="${MEDIA_OUTPUT_DIR}/output.$2"
}

media_publish_output() {
    local original="$1" destination="$2" backup="${3:-}"

    touch -r "${original}" "${MEDIA_OUTPUT_FILE}" || return
    chmod --reference="${original}" -- "${MEDIA_OUTPUT_FILE}" || return
    if [[ -n "${backup}" ]]; then
        cp -p -- "${original}" "${MEDIA_OUTPUT_DIR}/original" || return
        mv -nT -- "${MEDIA_OUTPUT_DIR}/original" "${backup}" || return
        [[ ! -e "${MEDIA_OUTPUT_DIR}/original" ]] || return 1
    fi
    if [[ "${destination}" == "${original}" ]]; then
        mv -fT -- "${MEDIA_OUTPUT_FILE}" "${destination}" || return
    else
        mv -nT -- "${MEDIA_OUTPUT_FILE}" "${destination}" || return
        [[ ! -e "${MEDIA_OUTPUT_FILE}" ]] || return 1
    fi
}

# Shared by the processors; each owns TEMP_DIR and at most one output candidate.
cleanup() {
    local status=$?
    media_discard_output || status=1
    [[ -z "${TEMP_DIR:-}" ]] || rm -rf -- "${TEMP_DIR}" || status=1
    return "${status}"
}

media_validate_boolean() {
    local name="$1"
    local value="$2"
    [[ "${value}" == "0" || "${value}" == "1" ]] ||
        media_die "${name} must be 0 or 1"
}
