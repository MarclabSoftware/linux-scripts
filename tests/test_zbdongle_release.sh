#!/usr/bin/env bash

# Parse synthetic release metadata only; no serial device or flasher is used.
set -Eeuo pipefail
command -v python3 >/dev/null || {
    printf 'Zigbee release test skipped: requires python3\n'
    exit 77
}
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export ZBDONGLE_ENV_FILE=/nonexistent
# shellcheck source=src/scripts/update_zbdonglee.sh
source "${REPO_ROOT}/src/scripts/update_zbdonglee.sh"
RESET_MODE=full
TARGET=zbdonglee
RECOVERY_INCLUDE_PRERELEASES=0
RUN_DIR="${TEST_TMP}"
curl() {
    local destination=""
    while (($#)); do
        if [[ "$1" == -o ]]; then
            destination="$2"
            shift
        fi
        shift
    done
    cp -- "${TEST_TMP}/fixture.json" "${destination}"
}
for mode in missing null app_only nvm_only both invalid; do
    python3 - "${TEST_TMP}/fixture.json" "${mode}" <<'PY'
import json, pathlib, sys
path, mode = sys.argv[1:]
app = {'name': 'EFR32MG21A020F768IM32_app_clear_0_786432_8192_16384.gbl',
       'browser_download_url': 'https://example.com/app.gbl'}
nvm = {'name': 'EFR32MG21A020F768IM32_nvm3_clear_0_786432_8192_16384_32768.gbl',
       'browser_download_url': 'https://example.com/nvm.gbl'}
if mode == 'null':
    app['digest'] = nvm['digest'] = None
if mode in ('app_only', 'both'):
    app['digest'] = 'sha256:' + 'a' * 64
if mode in ('nvm_only', 'both'):
    nvm['digest'] = 'sha256:' + 'b' * 64
release = {'tag_name': 'test|' if mode == 'invalid' else 'test', 'assets': [app, nvm]}
pathlib.Path(path).write_text(json.dumps(release))
PY
    if [[ "${mode}" == invalid ]]; then
        set +e
        (
            set -e
            recovery_assets
        ) >/dev/null 2>&1
        status=$?
        set -e
        [[ "${status}" != 0 ]]
        continue
    fi
    recovery_assets >/dev/null
    [[ "${RECOVERY_TAG}" == test ]]
    [[ "${APP_URL}" == https://example.com/app.gbl && "${NVM3_URL}" == https://example.com/nvm.gbl ]]
    [[ "${APP_ASSET}" == EFR32MG21A020F768IM32_app_clear_0_786432_8192_16384.gbl ]]
    [[ "${NVM3_ASSET}" == EFR32MG21A020F768IM32_nvm3_clear_0_786432_8192_16384_32768.gbl ]]
    if [[ "${mode}" == app_only || "${mode}" == both ]]; then
        [[ "${APP_SHA}" =~ ^a{64}$ ]]
    else
        [[ -z "${APP_SHA}" ]]
    fi
    if [[ "${mode}" == nvm_only || "${mode}" == both ]]; then
        [[ "${NVM3_SHA}" =~ ^b{64}$ ]]
    else
        [[ -z "${NVM3_SHA}" ]]
    fi
done
# Probe failure must preserve the caller's shell options; flash output must be
# saved successfully even when the firmware operation itself reports success.
fake_flasher() {
    printf '%s\n' 'NoFirmwareError'
    return "${FLASHER_STATUS}"
}
SUDO=()
FLASHER=(fake_flasher)
DEVICE=/dev/synthetic
PROBE_METHODS=ezsp
FLASHER_STATUS=3
set +e
probe failure >/dev/null
probe_status=$?
[[ $- != *e* && "${probe_status}" == 3 ]] || exit 1
set -e
flash /tmp/synthetic app-clear 1 >/dev/null
FLASHER_STATUS=0
tee() {
    cat >/dev/null
    return 1
}
# Expected failures are captured deliberately.
# shellcheck disable=SC2310
if probe output-failure >/dev/null; then
    printf 'probe ignored an output-write failure\n' >&2
    exit 1
fi
# shellcheck disable=SC2310
if (flash /tmp/synthetic output-failure) >/dev/null 2>&1; then
    printf 'flash ignored an output-write failure\n' >&2
    exit 1
fi
printf 'Zigbee release and helper tests passed\n'
