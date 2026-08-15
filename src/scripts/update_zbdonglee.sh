#!/usr/bin/env bash

# Silicon Labs Zigbee Coordinator Firmware Updater
# Version: 2.0.0
# Updated: 2026-07-29
#
# Safely flashes supported Sonoff ZBDongle-E and Dongle Plus MG24 coordinators
# with universal-silabs-flasher. The script can stop the matching Zigbee2MQTT
# Compose project during flashing and restart it afterward. Destructive NVM or
# application resets require a separate explicit confirmation.
#
# Host-specific device and firmware choices may be stored in
# update_zbdonglee.env beside this script. Process environment values remain
# useful for one-off invocations.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/update_zbdonglee.env"

die() {
    local now
    now="$(date '+%F %T')" || now="unknown"
    printf '[%s] ERROR: %s\n' "${now}" "$*" >&2
    exit 1
}

load_environment() {
    local env_file="${ZBDONGLE_ENV_FILE:-${DEFAULT_ENV_FILE}}"
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

load_environment

# Public defaults can be overridden when a different firmware build is needed.
URL_ZBDONGLEE="${URL_ZBDONGLEE:-https://github.com/Nerivec/silabs-firmware-builder/releases/download/v2026.6.0-pre1/sonoff_zbdonglee_zigbee_ncp_2026.6.0_9.1.0_115200_sw_flow.gbl}"
URL_MG24="${URL_MG24:-https://github.com/Nerivec/silabs-firmware-builder/releases/download/v2026.6.0-pre1/sonoff_dongle-pmg24_zigbee_ncp_2026.6.0_9.1.0_460800_sw_flow.gbl}"

# Normal use:
#   ./update_zbdonglee.sh
#
# Useful overrides:
#   DEVICE=/dev/ttyUSB0 TARGET=mg24 ./update_zbdonglee.sh
#   YES=1 ./update_zbdonglee.sh
#
# Destructive resets erase coordinator state and require RESET_CONFIRM=YES:
#   RESET_MODE=nvm3 RESET_CONFIRM=YES ./update_zbdonglee.sh
#   RESET_MODE=app  RESET_CONFIRM=YES ./update_zbdonglee.sh
#   RESET_MODE=full RESET_CONFIRM=YES ./update_zbdonglee.sh
DEVICE="${DEVICE:-}"
TARGET="${TARGET:-auto}"         # auto | zbdonglee | mg24
RESET_MODE="${RESET_MODE:-none}" # none | nvm3 | app | full
RESET_CONFIRM="${RESET_CONFIRM:-}"
YES="${YES:-0}"

STOP_Z2M="${STOP_Z2M:-1}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-zigbee2mqtt}"
RESTART_Z2M_ON_FLASH_FAILURE="${RESTART_Z2M_ON_FLASH_FAILURE:-0}"

RECOVERY_REPO="${RECOVERY_REPO:-Nerivec/silabs-firmware-recovery}"
RECOVERY_RELEASE="${RECOVERY_RELEASE:-latest}" # latest | a release tag
RECOVERY_INCLUDE_PRERELEASES="${RECOVERY_INCLUDE_PRERELEASES:-1}"

WORKDIR="${WORKDIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/zbdongle-flash}"
MIN_FIRMWARE_BYTES="${MIN_FIRMWARE_BYTES:-100000}"
MIN_CLEAR_BYTES="${MIN_CLEAR_BYTES:-10000}"

Z2M_STOPPED=0
FLASH_TOUCHED=0
Z2M_IDS=()
RUN_DIR=""
docker_ps_output=""

log() {
    local now
    now="$(date '+%F %T')" || now="unknown"
    printf '[%s] %s\n' "${now}" "$*"
}
warn() {
    local now
    now="$(date '+%F %T')" || now="unknown"
    printf '[%s] WARNING: %s\n' "${now}" "$*" >&2
}
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

cleanup() {
    local rc=$?
    if [[ "${Z2M_STOPPED}" == "1" ]]; then
        if [[ "${rc}" == "0" || "${FLASH_TOUCHED}" == "0" || "${RESTART_Z2M_ON_FLASH_FAILURE}" == "1" ]]; then
            log "Restarting Zigbee2MQTT..."
            docker start "${Z2M_IDS[@]}" >/dev/null || warn "Could not restart Zigbee2MQTT."
        else
            warn "Zigbee2MQTT remains stopped because flashing failed after modifying the coordinator."
            warn "Restart it manually with: docker start ${Z2M_IDS[*]}"
        fi
    fi
    [[ "${rc}" == "0" || -z "${RUN_DIR}" ]] || warn "Logs and temporary files remain in: ${RUN_DIR}"
    exit "${rc}"
}
trap cleanup EXIT

download() {
    local url="$1" dest="$2" min_bytes="$3" sha="${4:-}" tmp="${2}.part" size actual
    log "Downloading: ${url}"
    rm -f "${tmp}"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${tmp}" "${url}"
    size="$(wc -c <"${tmp}" | tr -d '[:space:]')"
    [[ "${size}" -ge "${min_bytes}" ]] || die "download is unexpectedly small (${size} bytes): ${url}"
    if [[ -n "${sha}" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            printf '%s  %s\n' "${sha}" "${tmp}" | sha256sum -c - >/dev/null
        else
            actual="$(shasum -a 256 "${tmp}" | awk '{print $1}')"
            [[ "${actual}" == "${sha}" ]] || die "SHA256 mismatch for ${url}"
        fi
    fi
    mv -f "${tmp}" "${dest}"
}

find_device() {
    local path lower
    CANDIDATES=()
    add() {
        for path in "${CANDIDATES[@]}"; do [[ "${path}" == "$1" ]] && return 0; done
        CANDIDATES+=("$1")
    }

    if [[ -n "${DEVICE}" ]]; then
        [[ -e "${DEVICE}" ]] || die "DEVICE does not exist: ${DEVICE}"
        lower="$(printf '%s' "${DEVICE}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${TARGET}" == "auto" && "${lower}" == *"mg24"* ]]; then TARGET="mg24"; fi
        if [[ "${TARGET}" == "auto" && "${lower}" == *"zbdongle"* ]]; then TARGET="zbdonglee"; fi
        if [[ "${TARGET}" == "auto" && "${lower}" == *"zigbee_3.0_usb_dongle_plus_v2"* ]]; then TARGET="zbdonglee"; fi
        [[ "${TARGET}" != "auto" ]] ||
            die "TARGET=zbdonglee or TARGET=mg24 is required with a manual DEVICE"
        return 0
    fi

    shopt -s nullglob nocaseglob
    if [[ "${TARGET}" == "auto" || "${TARGET}" == "zbdonglee" ]]; then
        for path in /dev/serial/by-id/usb-*Sonoff*Zigbee*3.0*USB*Dongle*Plus*V2* /dev/serial/by-id/usb-*ITEAD*SONOFF*Zigbee*3.0*USB*Dongle*Plus*V2*; do add "${path}"; done
    fi
    if [[ "${TARGET}" == "auto" || "${TARGET}" == "mg24" ]]; then
        for path in /dev/serial/by-id/usb-*SONOFF*Dongle*Plus*MG24* /dev/serial/by-id/usb-*Sonoff*Dongle*Plus*MG24*; do add "${path}"; done
    fi
    shopt -u nocaseglob

    [[ "${#CANDIDATES[@]}" -gt 0 ]] ||
        die "no supported coordinator found; set DEVICE=/dev/... and TARGET=zbdonglee|mg24"
    [[ "${#CANDIDATES[@]}" == "1" ]] ||
        die "multiple coordinator candidates found: ${CANDIDATES[*]}"
    DEVICE="${CANDIDATES[0]}"

    lower="$(printf '%s' "${DEVICE}" | tr '[:upper:]' '[:lower:]')"
    [[ "${TARGET}" != "auto" || "${lower}" != *"mg24"* ]] || TARGET="mg24"
    [[ "${TARGET}" != "auto" || "${lower}" != *"zbdongle"* ]] || TARGET="zbdonglee"
    [[ "${TARGET}" != "auto" || "${lower}" != *"zigbee_3.0_usb_dongle_plus_v2"* ]] || TARGET="zbdonglee"
    [[ "${TARGET}" != "auto" ]] ||
        die "cannot infer the coordinator type; set TARGET=zbdonglee or TARGET=mg24"
}

recovery_assets() {
    local api mode json out rc app_asset nvm3_asset
    [[ "${RESET_MODE}" == "none" ]] && return 0
    need python3

    if [[ "${RECOVERY_RELEASE}" == "latest" && "${RECOVERY_INCLUDE_PRERELEASES}" == "1" ]]; then
        api="https://api.github.com/repos/${RECOVERY_REPO}/releases?per_page=20"
        mode="list"
    elif [[ "${RECOVERY_RELEASE}" == "latest" ]]; then
        api="https://api.github.com/repos/${RECOVERY_REPO}/releases/latest"
        mode="single"
    else
        api="https://api.github.com/repos/${RECOVERY_REPO}/releases/tags/${RECOVERY_RELEASE}"
        mode="single"
    fi

    if [[ "${TARGET}" == "zbdonglee" ]]; then
        app_asset="EFR32MG21A020F768IM32_app_clear_0_786432_8192_16384.gbl"
        nvm3_asset="EFR32MG21A020F768IM32_nvm3_clear_0_786432_8192_16384_32768.gbl"
    else
        app_asset="EFR32MG24A420F1536IM48_app_clear_134217728_1572864_8192_134242304.gbl"
        nvm3_asset="EFR32MG24A420F1536IM48_nvm3_clear_134217728_1572864_8192_134242304_32768.gbl"
    fi

    json="${RUN_DIR}/recovery-release.json"
    log "Resolving recovery assets: ${RECOVERY_REPO} (${RECOVERY_RELEASE})"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${json}" "${api}"

    set +e
    out="$(
        python3 - "${json}" "${mode}" "${app_asset}" "${nvm3_asset}" <<'PY'
import json, sys
path, mode, app_name, nvm_name = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
rel = next((r for r in data if not r.get("draft")), None) if mode == "list" else data
if not rel:
    raise SystemExit("no suitable release found")
assets = {a.get("name"): a for a in rel.get("assets", [])}
def pick(name):
    a = assets.get(name)
    if not a:
        raise SystemExit(f"missing asset: {name}")
    digest = a.get("digest") or ""
    if digest.startswith("sha256:"):
        digest = digest.split(":", 1)[1]
    return a["browser_download_url"], digest
app_url, app_sha = pick(app_name)
nvm_url, nvm_sha = pick(nvm_name)
print("\t".join([rel.get("tag_name", ""), app_name, app_url, app_sha, nvm_name, nvm_url, nvm_sha]))
PY
    )"
    rc=$?
    set -e
    [[ "${rc}" == "0" ]] || die "could not resolve recovery assets"
    IFS=$'\t' read -r RECOVERY_TAG APP_ASSET APP_URL APP_SHA NVM3_ASSET NVM3_URL NVM3_SHA <<<"${out}"
    log "Selected recovery release: ${RECOVERY_TAG}"
}

flash() {
    local file="$1" label="$2" allow_clear_error="${3:-0}" rc
    local log_file="${RUN_DIR}/flash-${label}.log"
    FLASH_TOUCHED=1
    set +e
    "${SUDO[@]}" "${FLASHER[@]}" --device "${DEVICE}" --probe-methods "${PROBE_METHODS}" --bootloader-reset rts_dtr,baudrate flash --firmware "${file}" 2>&1 | tee "${log_file}"
    rc=${PIPESTATUS[0]}
    set -e
    [[ "${rc}" == "0" ]] && return 0
    if [[ "${allow_clear_error}" == "1" ]] && grep -Eq 'NoFirmwareError|No firmware exists|No application can be launched' "${log_file}"; then
        warn "Application clear completed without bootable firmware; continuing with the final firmware."
        return 0
    fi
    die "flash failed: ${label}"
}

probe() {
    local label="$1" rc
    local log_file="${RUN_DIR}/probe-${label}.log"
    set +e
    "${SUDO[@]}" "${FLASHER[@]}" --device "${DEVICE}" --probe-methods "${PROBE_METHODS}" probe 2>&1 | tee "${log_file}"
    rc=${PIPESTATUS[0]}
    set -e
    [[ "${rc}" == "0" ]]
}

validate_boolean() {
    local name="$1"
    local value="$2"
    [[ "${value}" == "0" || "${value}" == "1" ]] ||
        die "${name} must be 0 or 1"
}

validate_config() {
    case "${TARGET}" in
        auto | zbdonglee | mg24) ;;
        *) die "TARGET must be auto, zbdonglee or mg24" ;;
    esac
    case "${RESET_MODE}" in
        none | nvm3 | app | full) ;;
        *) die "RESET_MODE must be none, nvm3, app or full" ;;
    esac

    [[ "${RESET_MODE}" == "none" || "${RESET_CONFIRM}" == "YES" ]] ||
        die "RESET_MODE=${RESET_MODE} erases coordinator state; set RESET_CONFIRM=YES"
    validate_boolean YES "${YES}"
    validate_boolean STOP_Z2M "${STOP_Z2M}"
    validate_boolean RESTART_Z2M_ON_FLASH_FAILURE "${RESTART_Z2M_ON_FLASH_FAILURE}"
    validate_boolean RECOVERY_INCLUDE_PRERELEASES "${RECOVERY_INCLUDE_PRERELEASES}"
    [[ "${MIN_FIRMWARE_BYTES}" =~ ^[1-9][0-9]*$ ]] ||
        die "MIN_FIRMWARE_BYTES must be a positive integer"
    [[ "${MIN_CLEAR_BYTES}" =~ ^[1-9][0-9]*$ ]] ||
        die "MIN_CLEAR_BYTES must be a positive integer"
    [[ "${WORKDIR}" == /* ]] || die "WORKDIR must be an absolute path"
    [[ -z "${DEVICE}" || "${DEVICE}" == /dev/* ]] ||
        die "DEVICE must be a path below /dev"
    [[ "${URL_ZBDONGLEE}" =~ ^https:// ]] ||
        die "URL_ZBDONGLEE must use HTTPS"
    [[ "${URL_MG24}" =~ ^https:// ]] ||
        die "URL_MG24 must use HTTPS"
    [[ "${RECOVERY_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
        die "RECOVERY_REPO must use owner/repository syntax"
    [[ "${STOP_Z2M}" == "0" || -n "${COMPOSE_PROJECT}" ]] ||
        die "COMPOSE_PROJECT must not be empty when STOP_Z2M=1"
}

case "${1:-}" in
    --check-config)
        (($# == 1)) || die "--check-config accepts no additional arguments"
        validate_config
        printf 'update_zbdonglee configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf '%s\n' \
            'Usage: update_zbdonglee.sh [--check-config]' \
            'Configuration: update_zbdonglee.env beside the script or process environment.'
        exit 0
        ;;
    "")
        (($# == 0)) || die "unexpected arguments"
        ;;
    *) die "unknown argument: $1" ;;
esac

validate_config

need curl
need tee
need wc
find_device

case "${TARGET}" in
    zbdonglee)
        FW_URL="${URL_ZBDONGLEE}"
        BAUD="115200"
        TOKEN="zbdonglee"
        PROBE_METHODS="ezsp:115200,bootloader:115200"
        ;;
    mg24)
        FW_URL="${URL_MG24}"
        BAUD="460800"
        TOKEN="mg24"
        PROBE_METHODS="ezsp:460800,bootloader:115200"
        ;;
    *) die "unsupported TARGET after device detection: ${TARGET}" ;;
esac

fw_lower="$(printf '%s' "${FW_URL}" | tr '[:upper:]' '[:lower:]')"
[[ "${fw_lower}" == *.gbl ]] || die "firmware URL does not name a .gbl file: ${FW_URL}"
[[ "${fw_lower}" == *"${TOKEN}"* ]] ||
    die "firmware URL does not match target ${TARGET}: ${FW_URL}"
[[ "${fw_lower}" == *"${BAUD}"* ]] ||
    die "firmware URL does not contain expected baud rate ${BAUD}: ${FW_URL}"

SUDO=()
if [[ ! -r "${DEVICE}" || ! -w "${DEVICE}" ]]; then SUDO=(sudo); fi

if [[ -n "${FLASHER_BIN:-}" ]]; then
    FLASHER=("${FLASHER_BIN}")
elif FLASHER_CMD="$(command -v universal-silabs-flasher 2>/dev/null)"; then
    FLASHER=("${FLASHER_CMD}")
elif FLASHER_CMD="$(command -v uvx 2>/dev/null)"; then
    FLASHER=("${FLASHER_CMD}" universal-silabs-flasher)
elif FLASHER_CMD="$(command -v uv 2>/dev/null)"; then
    FLASHER=("${FLASHER_CMD}" tool run universal-silabs-flasher)
elif [[ -x /usr/local/bin/uv ]] || { [[ "${#SUDO[@]}" -gt 0 ]] && sudo -n test -x /usr/local/bin/uv 2>/dev/null; }; then
    FLASHER=(/usr/local/bin/uv tool run universal-silabs-flasher)
else
    die "install universal-silabs-flasher, uvx or uv"
fi

RUN_DIR="${WORKDIR}/$(date '+%Y%m%d-%H%M%S')-${TARGET}"
mkdir -p "${RUN_DIR}"
recovery_assets

FW_FILE="${RUN_DIR}/${FW_URL##*/}"
APP_FILE="${RUN_DIR}/${APP_ASSET:-app-clear.gbl}"
NVM3_FILE="${RUN_DIR}/${NVM3_ASSET:-nvm3-clear.gbl}"

printf '\nTarget: %s\nDevice: %s\nFirmware: %s\nReset: %s\nLog: %s\n' "${TARGET}" "${DEVICE}" "${FW_URL##*/}" "${RESET_MODE}" "${RUN_DIR}"
[[ "${RESET_MODE}" == "none" ]] || printf 'Recovery: %s\n' "${RECOVERY_TAG}"
if [[ "${YES}" != "1" ]]; then
    read -r -p "Type FLASH to continue: " answer || die "could not read confirmation"
    [[ "${answer}" == "FLASH" ]] || die "operation cancelled"
fi

download "${FW_URL}" "${FW_FILE}" "${MIN_FIRMWARE_BYTES}"
[[ "${RESET_MODE}" != "app" && "${RESET_MODE}" != "full" ]] || download "${APP_URL}" "${APP_FILE}" "${MIN_CLEAR_BYTES}" "${APP_SHA}"
[[ "${RESET_MODE}" != "nvm3" && "${RESET_MODE}" != "full" ]] || download "${NVM3_URL}" "${NVM3_FILE}" "${MIN_CLEAR_BYTES}" "${NVM3_SHA}"

if [[ "${STOP_Z2M}" == "1" ]]; then
    need docker
    docker_ps_output="$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}")"
    while IFS= read -r id; do [[ -n "${id}" ]] && Z2M_IDS+=("${id}"); done <<<"${docker_ps_output}"
    if [[ "${#Z2M_IDS[@]}" -gt 0 ]]; then
        log "Stopping Zigbee2MQTT..."
        docker stop "${Z2M_IDS[@]}" >/dev/null
        Z2M_STOPPED=1
    fi
fi

# probe() captures PIPESTATUS and deliberately returns it to this fallback.
# shellcheck disable=SC2310
probe before || warn "Initial probe failed; attempting bootloader-reset flashing anyway."
case "${RESET_MODE}" in
    none) flash "${FW_FILE}" firmware ;;
    nvm3)
        flash "${NVM3_FILE}" nvm3-clear
        flash "${FW_FILE}" firmware-after-nvm3
        ;;
    app)
        flash "${APP_FILE}" app-clear 1
        flash "${FW_FILE}" firmware-after-app-clear
        ;;
    full)
        flash "${APP_FILE}" app-clear 1
        flash "${FW_FILE}" firmware-after-app-clear
        flash "${NVM3_FILE}" nvm3-clear
        flash "${FW_FILE}" firmware-final
        ;;
    *) die "unsupported RESET_MODE after validation: ${RESET_MODE}" ;;
esac
# The final probe status is deliberately promoted to a fatal error.
# shellcheck disable=SC2310
probe after || die "final probe failed"
log "Firmware update completed."
