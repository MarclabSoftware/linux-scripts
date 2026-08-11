#!/usr/bin/env bash

# Validate Raspberry Pi EEPROM and boot configuration without touching a host.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=../src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=../src/init/scripts/rpi_eeprom.sh
. "${REPO_ROOT}/src/init/scripts/rpi_eeprom.sh"
# shellcheck source=../src/init/scripts/rpi_boot_config.sh
. "${REPO_ROOT}/src/init/scripts/rpi_boot_config.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

CONFIG_RPI_EEPROM_RELEASE="default"
validateRpiEepromConfiguration
CONFIG_RPI_EEPROM_RELEASE="latest"
validateRpiEepromConfiguration
CONFIG_RPI_EEPROM_RELEASE="stable"
expect_failure validateRpiEepromConfiguration

unset CONFIG_RPI_BOOT_SETTINGS
CONFIG_RPI_BOOT_SETTINGS="arm_freq=2600"
expect_failure validateRpiBootConfiguration

unset CONFIG_RPI_BOOT_SETTINGS
declare -a CONFIG_RPI_BOOT_SETTINGS=()
expect_failure validateRpiBootConfiguration

CONFIG_RPI_BOOT_SETTINGS=($'arm_freq=2600\nforce_turbo=1')
expect_failure validateRpiBootConfiguration
CONFIG_RPI_BOOT_SETTINGS=("$(printf 'x%.0s' {1..99})")
expect_failure validateRpiBootConfiguration
CONFIG_RPI_BOOT_SETTINGS=("include ${RPI_MANAGED_BOOT_FRAGMENT}")
expect_failure validateRpiBootConfiguration

CONFIG_RPI_BOOT_SETTINGS=(
    '[pi5]'
    'dtoverlay=disable-wifi-pi5'
    'arm_freq_min=600'
)
validateRpiBootConfiguration

# Runtime platform and external commands are replaced with harmless fakes.
isRaspberryPi() {
    return 0
}
checkCommand() {
    return 0
}
rpi-eeprom-update() {
    printf '%s\n' "$*" >>"${TEST_TMP}/eeprom-command.log"
}

eeprom_defaults="${TEST_TMP}/etc/default/rpi-eeprom-update"
mkdir -p -- "${eeprom_defaults%/*}"
printf '%s\n' \
    '# Package defaults' \
    'FIRMWARE_RELEASE_STATUS="stable"' \
    'FIRMWARE_RELEASE_STATUS=critical' \
    'OTHER_SETTING=1' >"${eeprom_defaults}"
chmod 0600 -- "${eeprom_defaults}"

CONFIG_RPI_EEPROM_RELEASE="latest"
configureRpiEeprom "${eeprom_defaults}" >/dev/null
grep -qxF 'FIRMWARE_RELEASE_STATUS="latest"' "${eeprom_defaults}"
assignment_count="$(grep -c '^FIRMWARE_RELEASE_STATUS=' "${eeprom_defaults}")"
[[ "${assignment_count}" == 1 ]]
grep -qxF 'OTHER_SETTING=1' "${eeprom_defaults}"
grep -qxF -- '-a' "${TEST_TMP}/eeprom-command.log"
eeprom_mode="$(stat -c '%a' -- "${eeprom_defaults}")"
[[ "${eeprom_mode}" == 644 ]]

boot_config="${TEST_TMP}/boot/firmware/config.txt"
mkdir -p -- "${boot_config%/*}"
printf '%s\n' \
    '# Base distribution configuration' \
    '[pi5]' \
    'arm_boost=1' >"${boot_config}"
chmod 0755 -- "${boot_config}"

configureRpiBoot "${boot_config}" >/dev/null
fragment="${boot_config%/*}/${RPI_MANAGED_BOOT_FRAGMENT}"
grep -qxF '# Managed by linux-scripts init.' "${fragment}"
grep -qxF 'dtoverlay=disable-wifi-pi5' "${fragment}"
grep -qxF 'arm_freq_min=600' "${fragment}"
all_filter_count="$(grep -cFx '[all]' "${fragment}")"
[[ "${all_filter_count}" == 2 ]]
grep -qxF "include ${RPI_MANAGED_BOOT_FRAGMENT}" "${boot_config}"
fragment_mode="$(stat -c '%a' -- "${fragment}")"
boot_config_mode="$(stat -c '%a' -- "${boot_config}")"
[[ "${fragment_mode}" == 644 ]]
[[ "${boot_config_mode}" == 644 ]]

# Reapplying the same configuration must not duplicate the include.
configureRpiBoot "${boot_config}" >/dev/null
include_count="$(
    grep -cFx "include ${RPI_MANAGED_BOOT_FRAGMENT}" "${boot_config}"
)"
[[ "${include_count}" == 1 ]]

printf 'init Raspberry Pi tests passed\n'
