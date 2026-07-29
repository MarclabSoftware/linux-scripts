#!/usr/bin/env bash

# Configuration and archive-safety checks for the media script suite.

set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA_DIR="${REPOSITORY_DIR}/src/scripts/media"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT

for script_name in \
    archive_source_files.sh \
    convert_to_mp4.sh \
    fix_corrupt_images.sh \
    standardize_mp4.sh; do
    MEDIA_ENV_FILE=/nonexistent \
        "${MEDIA_DIR}/${script_name}" --check-config >/dev/null
done
FFMPEG_INSTALL_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/install_static_ffmpeg.sh" --check-config >/dev/null

invalid_env="${TEST_DIR}/invalid.env"
printf 'MEDIA_VIDEO_CRF=52\n' >"${invalid_env}"
if MEDIA_ENV_FILE="${invalid_env}" \
    "${MEDIA_DIR}/convert_to_mp4.sh" --check-config >/dev/null 2>&1; then
    printf 'invalid media configuration was accepted\n' >&2
    exit 1
fi

scan_dir="${TEST_DIR}/scan"
archive_dir="${TEST_DIR}/archive"
mkdir -p -- "${scan_dir}/nested" "${archive_dir}/nested"
printf 'source\n' >"${scan_dir}/nested/video.avi"
printf 'converted\n' >"${scan_dir}/nested/video.mp4"

MEDIA_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/archive_source_files.sh" --dry-run \
    "${scan_dir}" "${archive_dir}" >/dev/null
[[ -f "${scan_dir}/nested/video.avi" ]]
[[ ! -e "${archive_dir}/nested/video.avi" ]]

MEDIA_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/archive_source_files.sh" \
    "${scan_dir}" "${archive_dir}" >/dev/null
[[ ! -e "${scan_dir}/nested/video.avi" ]]
[[ -f "${archive_dir}/nested/video.avi" ]]

printf 'new source\n' >"${scan_dir}/nested/video.avi"
MEDIA_ENV_FILE=/nonexistent \
    "${MEDIA_DIR}/archive_source_files.sh" \
    "${scan_dir}" "${archive_dir}" >/dev/null
[[ -f "${scan_dir}/nested/video.avi" ]]
archived_content="$(cat -- "${archive_dir}/nested/video.avi")"
[[ "${archived_content}" == "source" ]]

printf 'media configuration tests passed\n'
