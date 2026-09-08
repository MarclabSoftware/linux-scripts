#!/usr/bin/env bash

# Exercise stream preservation and failed publication with generated media.
set -Eeuo pipefail
IFS=$'\n\t'

for command_name in ffmpeg ffprobe; do
    command -v "${command_name}" >/dev/null || {
        printf 'media integrity tests skipped: %s is unavailable\n' "${command_name}"
        exit 77
    }
done
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
MEDIA_DIR="${REPO_ROOT}/src/scripts/media"
readonly MEDIA_DIR
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export MEDIA_ENV_FILE=/nonexistent MEDIA_VIDEO_PRESET=ultrafast MEDIA_IDET_FRAMES=20 MEDIA_MIN_VIDEO_BYTES=1

mkdir -- "${TEST_TMP}/convert" "${TEST_TMP}/standardize" "${TEST_TMP}/legacy" "${TEST_TMP}/bin"
printf '1\n00:00:00,000 --> 00:00:01,000\nRetained subtitle\n' >"${TEST_TMP}/subtitle.srt"
cat >"${TEST_TMP}/metadata" <<'EOF'
;FFMETADATA1
title=Retained title
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=Retained chapter
EOF
ffmpeg -nostdin -hide_banner -v error \
    -f lavfi -i testsrc=size=32x32:rate=5:duration=1 \
    -f lavfi -i sine=frequency=440:duration=1 \
    -f lavfi -i sine=frequency=880:duration=1 \
    -i "${TEST_TMP}/subtitle.srt" -i "${TEST_TMP}/metadata" \
    -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
    -metadata:s:a:0 language=ita -metadata:s:a:1 language=eng \
    -c:v libx264 -pix_fmt yuv420p -threads 1 -c:a aac -c:s srt \
    "${TEST_TMP}/convert/multiple.mkv"
ffmpeg -nostdin -hide_banner -v error -i "${TEST_TMP}/convert/multiple.mkv" \
    -map 0 -c copy -c:s mov_text "${TEST_TMP}/standardize/multiple.mp4"
chmod 0640 -- "${TEST_TMP}/standardize/multiple.mp4"

assert_streams() {
    local audio_count subtitle_count languages title chapter
    audio_count="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l)"
    subtitle_count="$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$1" | wc -l)"
    languages="$(ffprobe -v error -select_streams a -show_entries stream_tags=language -of default=nw=1:nk=1 "$1")"
    title="$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$1")"
    chapter="$(ffprobe -v error -show_entries chapter_tags=title -of default=nw=1:nk=1 "$1")"
    [[ "${audio_count}" == 2 && "${subtitle_count}" == 1 ]]
    [[ "${languages}" == $'ita\neng' && "${title}" == 'Retained title' && "${chapter}" == 'Retained chapter' ]]
}

"${MEDIA_DIR}/convert_to_mp4.sh" "${TEST_TMP}/convert" >/dev/null 2>&1
assert_streams "${TEST_TMP}/convert/multiple.mp4"
"${MEDIA_DIR}/standardize_mp4.sh" "${TEST_TMP}/standardize" >/dev/null 2>&1
assert_streams "${TEST_TMP}/standardize/multiple.mp4"
mode="$(stat -c %a -- "${TEST_TMP}/standardize/multiple.mp4")"
[[ "${mode}" == 640 ]]

# Legacy video and non-MP4 audio exercise the transcoding path too.
ffmpeg -nostdin -hide_banner -v error \
    -f lavfi -i testsrc=size=32x32:rate=5:duration=1 \
    -f lavfi -i sine=frequency=440:duration=1 \
    -c:v mpeg4 -pix_fmt yuv420p -threads 1 -c:a pcm_s16le \
    "${TEST_TMP}/legacy/sample.avi"
"${MEDIA_DIR}/convert_to_mp4.sh" "${TEST_TMP}/legacy" >/dev/null 2>&1
codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "${TEST_TMP}/legacy/sample.mp4")"
[[ "${codec}" == h264 ]]

cat >"${TEST_TMP}/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MEDIA_TEST_FAILURE}" == mv ]]; then
    exit 23
fi
if [[ "${MEDIA_TEST_FAILURE}" == collision && "${*: -1}" == *.mp4 ]]; then
    printf 'concurrent output\n' >"${*: -1}"
fi
exec /usr/bin/mv "$@"
EOF
cat >"${TEST_TMP}/bin/touch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MEDIA_TEST_FAILURE}" != touch ]] || exit 24
exec /usr/bin/touch "$@"
EOF
chmod 0700 -- "${TEST_TMP}/bin/mv" "${TEST_TMP}/bin/touch"
export MEDIA_TEST_FAILURE

for MEDIA_TEST_FAILURE in touch mv; do
    before="$(sha256sum "${TEST_TMP}/standardize/multiple.mp4")"
    if PATH="${TEST_TMP}/bin:${PATH}" "${MEDIA_DIR}/standardize_mp4.sh" \
        "${TEST_TMP}/standardize" >"${TEST_TMP}/output" 2>&1; then
        printf 'standardizer accepted failed %s\n' "${MEDIA_TEST_FAILURE}" >&2
        exit 1
    fi
    after="$(sha256sum "${TEST_TMP}/standardize/multiple.mp4")"
    [[ "${after}" == "${before}" ]]
    if grep -Fq '[INFO] Updated ' "${TEST_TMP}/output"; then
        printf 'failed publication reported success\n' >&2
        exit 1
    fi
done

MEDIA_TEST_FAILURE=collision
rm -- "${TEST_TMP}/convert/multiple.mp4"
if PATH="${TEST_TMP}/bin:${PATH}" "${MEDIA_DIR}/convert_to_mp4.sh" \
    "${TEST_TMP}/convert" >/dev/null 2>&1; then
    printf 'converter accepted a concurrent destination\n' >&2
    exit 1
fi
grep -qxF 'concurrent output' "${TEST_TMP}/convert/multiple.mp4"

# Image repair must not report success after its final write failed.
cat >"${TEST_TMP}/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last="${*: -1}"
if [[ "${last}" == - ]]; then
    [[ " $* " == *'.media-output.'* ]]
else
    printf 'repaired-image\n' >"${last}"
fi
EOF
chmod 0700 -- "${TEST_TMP}/bin/ffmpeg"
mkdir -- "${TEST_TMP}/images"
printf 'original-image\n' >"${TEST_TMP}/images/sample.png"
MEDIA_TEST_FAILURE='mv'
if MEDIA_MARK_UNREPAIRABLE=0 PATH="${TEST_TMP}/bin:${PATH}" \
    "${MEDIA_DIR}/fix_corrupt_images.sh" "${TEST_TMP}/images" >"${TEST_TMP}/output" 2>&1; then
    printf 'image repair accepted failed publication\n' >&2
    exit 1
fi
grep -qxF original-image "${TEST_TMP}/images/sample.png"
if grep -Fq '[INFO] Repaired ' "${TEST_TMP}/output"; then
    printf 'failed image publication reported success\n' >&2
    exit 1
fi
leftover="$(find "${TEST_TMP}" -type d -name '.media-output.*' -print -quit)"
[[ -z "${leftover}" ]]

printf 'Media integrity tests passed\n'
