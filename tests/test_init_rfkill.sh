#!/usr/bin/env bash

# Validate RFKill target parsing and command construction without touching
# real radio hardware.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# shellcheck source=../src/init/scripts/rfkill.sh
. "${REPO_ROOT}/src/init/scripts/rfkill.sh"

declare -a targets=()
parseRfkillTargets "wlan, bluetooth,2" targets
[[ "${targets[*]}" == "wlan bluetooth 2" ]]

for invalid_targets in "" "wlan0" "wlan, ,bluetooth" "-1"; do
    set +e
    validateRfkillTargets "${invalid_targets}" 2>/dev/null
    validation_status=$?
    set -e
    if ((validation_status == 0)); then
        printf 'invalid RFKill targets were accepted: %s\n' \
            "${invalid_targets:-<empty>}" >&2
        exit 1
    fi
done

checkCommand() {
    return 1
}

CONFIG_RFKILL_TARGETS="wlan"
set +e
blockRf >/dev/null 2>&1
missing_command_status=$?
set -e
if ((missing_command_status == 0)); then
    printf 'blockRf accepted a missing rfkill command\n' >&2
    exit 1
fi

command_log="$(mktemp)"
readonly command_log
trap 'rm -f -- "${command_log}"' EXIT

checkCommand() {
    return 0
}

rfkill() {
    printf '%s\n' "$*" >"${command_log}"
}

CONFIG_RFKILL_TARGETS="wlan, bluetooth,2"
blockRf >/dev/null
grep -qxF 'block wlan bluetooth 2' "${command_log}"

printf 'init RFKill tests passed\n'
