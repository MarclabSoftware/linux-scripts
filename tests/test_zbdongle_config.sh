#!/usr/bin/env bash

# Configuration-only checks for update_zbdonglee.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPOSITORY_DIR}/src/scripts/update_zbdonglee.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT

ZBDONGLE_ENV_FILE=/nonexistent "${SCRIPT}" --check-config >/dev/null

invalid_env="${TEST_DIR}/invalid.env"
printf 'TARGET=unsupported\n' >"${invalid_env}"
if ZBDONGLE_ENV_FILE="${invalid_env}" "${SCRIPT}" --check-config >/dev/null 2>&1; then
    printf 'invalid Zigbee target was accepted\n' >&2
    exit 1
fi

printf 'TARGET=mg24\nDEVICE=/dev/ttyACM0\n' >"${invalid_env}"
ZBDONGLE_ENV_FILE="${invalid_env}" "${SCRIPT}" --check-config >/dev/null

chmod 0666 "${invalid_env}"
if ZBDONGLE_ENV_FILE="${invalid_env}" "${SCRIPT}" --check-config >/dev/null 2>&1; then
    printf 'writable Zigbee environment file was accepted\n' >&2
    exit 1
fi

printf 'Zigbee coordinator configuration tests passed\n'
