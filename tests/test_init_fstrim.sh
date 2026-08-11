#!/usr/bin/env bash

# Validate fstrim and USB UNMAP configuration without touching a host.
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
# shellcheck source=../src/init/scripts/fstrim.sh
. "${REPO_ROOT}/src/init/scripts/fstrim.sh"

expect_failure() {
    local status

    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    ((status != 0)) || {
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    }
}

unset CONFIG_FSTRIM_USB_UNMAP_IDS
expect_failure validateFstrimConfiguration
CONFIG_FSTRIM_USB_UNMAP_IDS="1234:abcd"
expect_failure validateFstrimConfiguration
unset CONFIG_FSTRIM_USB_UNMAP_IDS
declare -a CONFIG_FSTRIM_USB_UNMAP_IDS=("1234:abcd" "ABCD:0123")
validateFstrimConfiguration
CONFIG_FSTRIM_USB_UNMAP_IDS=("123:abcd")
expect_failure validateFstrimConfiguration
CONFIG_FSTRIM_USB_UNMAP_IDS=("1234:xyz1")
expect_failure validateFstrimConfiguration

CONFIG_FSTRIM_USB_UNMAP_IDS=("1234:abcd" "ABCD:0123")
command_log="${TEST_TMP}/commands.log"
readonly command_log

checkCommand() {
    return 0
}
udevadm() {
    printf 'udevadm %s\n' "$*" >>"${command_log}"
}
systemctl() {
    printf 'systemctl %s\n' "$*" >>"${command_log}"
}

legacy_rule="${TEST_TMP}/etc/udev/rules.d/21-ssd_trim.rules"
mkdir -p -- "${legacy_rule%/*}"
printf 'legacy\n' >"${legacy_rule}"

configureFstrim "${TEST_TMP}" >/dev/null

rules_file="${TEST_TMP}/etc/udev/rules.d/${FSTRIM_USB_RULE_NAME}"
grep -qxF '# Managed by linux-scripts init.' "${rules_file}"
grep -qxF 'ACTION=="add|change", SUBSYSTEM=="scsi_disk", ATTRS{idVendor}=="1234", ATTRS{idProduct}=="abcd", TEST=="provisioning_mode", ATTR{provisioning_mode}="unmap"' \
    "${rules_file}"
grep -qxF 'ACTION=="add|change", SUBSYSTEM=="scsi_disk", ATTRS{idVendor}=="abcd", ATTRS{idProduct}=="0123", TEST=="provisioning_mode", ATTR{provisioning_mode}="unmap"' \
    "${rules_file}"
[[ ! -e "${legacy_rule}" ]]
rules_mode="$(stat -c '%a' -- "${rules_file}")"
[[ "${rules_mode}" == 644 ]]
grep -qxF 'udevadm control --reload-rules' "${command_log}"
grep -qxF 'systemctl enable --now fstrim.timer' "${command_log}"
if grep -q 'udevadm trigger\|fstrim --all\|fstrim -a' "${command_log}"; then
    printf 'fstrim configuration performed an immediate device operation\n' >&2
    exit 1
fi

# Removing all quirks deletes only the managed rule and keeps the timer.
: >"${command_log}"
CONFIG_FSTRIM_USB_UNMAP_IDS=()
configureFstrim "${TEST_TMP}" >/dev/null
[[ ! -e "${rules_file}" ]]
grep -qxF 'udevadm control --reload-rules' "${command_log}"
grep -qxF 'systemctl enable --now fstrim.timer' "${command_log}"

printf 'init fstrim tests passed\n'
