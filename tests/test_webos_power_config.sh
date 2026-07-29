#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

private_key="${TEST_TMP}/webos.key"
state_file="${TEST_TMP}/online"
options_file="${TEST_TMP}/power_state.conf"
: >"${private_key}"
printf '1\n' >"${state_file}"
: >"${options_file}"
chmod 0600 "${private_key}" "${state_file}" "${options_file}"

webos_env="${TEST_TMP}/webos.env"
cat >"${webos_env}" <<EOF
WEBOS_HOST=192.0.2.10
WEBOS_PRIVATE_KEY=${private_key}
WEBOS_TOKEN_CACHE=${TEST_TMP}/state/token
WEBOS_KNOWN_HOSTS=${TEST_TMP}/state/known_hosts
EOF
chmod 0600 "${webos_env}"
WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" --check-config |
    grep -Fx 'webos_devmode configuration is valid' >/dev/null

power_env="${TEST_TMP}/power.env"
cat >"${power_env}" <<EOF
POWER_STATE_SOURCE_FILE=${state_file}
POWER_STATE_MQTT_OPTIONS_FILE=${options_file}
EOF
chmod 0600 "${power_env}"
POWER_STATE_ENV_FILE="${power_env}" \
    "${REPO_ROOT}/src/scripts/power_state.sh" --check-config |
    grep -Fx 'power_state configuration is valid' >/dev/null
