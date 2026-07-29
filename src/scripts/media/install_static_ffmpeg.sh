#!/usr/bin/env bash

# Verified Static FFmpeg Installer
# Version: 2.0.0
# Updated: 2026-07-29
#
# Downloads a current BtbN GPL static build, verifies it against the release
# checksum manifest, and installs ffmpeg/ffprobe plus optional ffplay. x86_64
# and aarch64 Linux are detected automatically; other architectures fail closed.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/install_static_ffmpeg.env"
readonly RELEASE_BASE_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"

die() {
    printf 'install_static_ffmpeg: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "$1" "$2" >&2
}

load_environment() {
    local env_file="${FFMPEG_INSTALL_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] ||
        die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) ||
        die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command not found: $1"
}

detect_target() {
    local architecture
    architecture="$(uname -m)"
    case "${architecture}" in
        x86_64 | amd64) printf 'linux64\n' ;;
        aarch64 | arm64) printf 'linuxarm64\n' ;;
        *) die "BtbN does not publish a supported static build for architecture: ${architecture}" ;;
    esac
}

load_environment

INSTALL_DIR="${FFMPEG_INSTALL_DIR:-/usr/local/bin}"
INSTALL_FFPLAY="${FFMPEG_INSTALL_FFPLAY:-1}"
TARGET="${FFMPEG_BUILD_TARGET:-$(detect_target)}"
default_archive_name="ffmpeg-master-latest-${TARGET}-gpl.tar.xz"
DOWNLOAD_URL="${FFMPEG_STATIC_URL:-${RELEASE_BASE_URL}/${default_archive_name}}"
ARCHIVE_NAME="${DOWNLOAD_URL##*/}"
CHECKSUMS_URL="${FFMPEG_CHECKSUMS_URL:-${RELEASE_BASE_URL}/checksums.sha256}"

validate_config() {
    [[ "${INSTALL_DIR}" == /* && "${INSTALL_DIR}" != "/" ]] ||
        die "FFMPEG_INSTALL_DIR must be an absolute directory other than /"
    [[ "${TARGET}" == "linux64" || "${TARGET}" == "linuxarm64" ]] ||
        die "FFMPEG_BUILD_TARGET must be linux64 or linuxarm64"
    [[ "${DOWNLOAD_URL}" =~ ^https:// ]] || die "FFMPEG_STATIC_URL must use HTTPS"
    [[ "${CHECKSUMS_URL}" =~ ^https:// ]] || die "FFMPEG_CHECKSUMS_URL must use HTTPS"
    [[ "${ARCHIVE_NAME}" =~ ^[A-Za-z0-9._-]+\.tar\.xz$ ]] ||
        die "FFMPEG_STATIC_URL must end with a safe .tar.xz filename"
    [[ "${INSTALL_FFPLAY}" == "0" || "${INSTALL_FFPLAY}" == "1" ]] ||
        die "FFMPEG_INSTALL_FFPLAY must be 0 or 1"
}

case "${1:-}" in
    --check-config)
        (($# == 1)) || die "--check-config accepts no additional arguments"
        validate_config
        printf 'install_static_ffmpeg configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf '%s\n' \
            'Usage: sudo install_static_ffmpeg.sh [--check-config]' \
            'Configuration: install_static_ffmpeg.env beside the script.'
        exit 0
        ;;
    "")
        (($# == 0)) || die "unexpected arguments"
        ;;
    *) die "unknown argument: $1" ;;
esac

validate_config
((EUID == 0)) || die "run this installer as root"
for command_name in awk curl dirname find install mktemp sha256sum tar uname; do
    require_command "${command_name}"
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/install_static_ffmpeg.XXXXXX")"
readonly work_dir
trap 'rm -rf -- "${work_dir}"' EXIT
archive_path="${work_dir}/${ARCHIVE_NAME}"
checksums_path="${work_dir}/checksums.sha256"

log INFO "Downloading ${ARCHIVE_NAME}"
curl -fL --retry 3 --connect-timeout 20 -o "${archive_path}" "${DOWNLOAD_URL}"
curl -fL --retry 3 --connect-timeout 20 -o "${checksums_path}" "${CHECKSUMS_URL}"

expected_checksum="$(
    awk -v archive="${ARCHIVE_NAME}" '
        {
            name = $2
            sub(/^\*/, "", name)
            if (name == archive) {
                print $1
                exit
            }
        }
    ' "${checksums_path}"
)"
[[ "${expected_checksum}" =~ ^[[:xdigit:]]{64}$ ]] ||
    die "checksum manifest does not contain ${ARCHIVE_NAME}"
printf '%s  %s\n' "${expected_checksum}" "${archive_path}" | sha256sum -c -

tar -xJf "${archive_path}" -C "${work_dir}"
ffmpeg_path="$(find "${work_dir}" -type f -path '*/bin/ffmpeg' -print -quit)"
[[ -n "${ffmpeg_path}" ]] || die "ffmpeg binary not found in archive"
binary_dir="$(dirname -- "${ffmpeg_path}")"
[[ -x "${binary_dir}/ffprobe" ]] || die "ffprobe binary not found in archive"
"${binary_dir}/ffmpeg" -version >/dev/null
"${binary_dir}/ffprobe" -version >/dev/null

install -d -m 0755 -- "${INSTALL_DIR}"
install -m 0755 -- "${binary_dir}/ffmpeg" "${binary_dir}/ffprobe" "${INSTALL_DIR}/"
if [[ "${INSTALL_FFPLAY}" == "1" && -x "${binary_dir}/ffplay" ]]; then
    install -m 0755 -- "${binary_dir}/ffplay" "${INSTALL_DIR}/"
fi

log INFO "Installed verified FFmpeg binaries in ${INSTALL_DIR}"
