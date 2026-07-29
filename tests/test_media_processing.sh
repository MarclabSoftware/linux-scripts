#!/usr/bin/env bash

# Minimal end-to-end checks for the media processing scripts.

set -Eeuo pipefail
IFS=$'\n\t'

for command_name in ffmpeg ffprobe; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'media processing test skipped: %s is unavailable\n' "${command_name}"
        exit 0
    fi
done

REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA_DIR="${REPOSITORY_DIR}/src/scripts/media"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT

video_dir="${TEST_DIR}/video"
image_dir="${TEST_DIR}/images"
mkdir -p -- "${video_dir}" "${image_dir}"

ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i testsrc=size=32x32:rate=5:duration=1 \
    -f lavfi -i sine=frequency=440:duration=1 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac \
    "${video_dir}/sample.mkv"

MEDIA_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/convert_to_mp4.sh" "${video_dir}" >/dev/null
[[ -s "${video_dir}/sample.mkv" && -s "${video_dir}/sample.mp4" ]]
ffprobe -v error -select_streams v:0 "${video_dir}/sample.mp4" >/dev/null

MEDIA_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/standardize_mp4.sh" "${video_dir}" >/dev/null
ffprobe -v error -select_streams v:0 "${video_dir}/sample.mp4" >/dev/null

ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i color=c=red:s=16x16 -frames:v 1 \
    -update 1 "${image_dir}/valid.png"
printf 'not an image\n' >"${image_dir}/corrupt.jpg"

if MEDIA_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/fix_corrupt_images.sh" "${image_dir}" >/dev/null 2>&1; then
    printf 'corrupt image scan unexpectedly reported complete success\n' >&2
    exit 1
fi
[[ -s "${image_dir}/valid.png" ]]
[[ -f "${image_dir}/corrupt.jpg.BROKEN" ]]

printf 'media processing integration test passed\n'
