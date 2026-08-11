#!/usr/bin/env bash

# Validate additive group membership and sudoers management without touching
# host accounts or the real sudo policy.
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
# shellcheck source=../src/init/scripts/user_groups.sh
. "${REPO_ROOT}/src/init/scripts/user_groups.sh"
# shellcheck source=../src/init/scripts/user_passwordless_sudo.sh
. "${REPO_ROOT}/src/init/scripts/user_passwordless_sudo.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

declare -a parsed_groups=()
parseUserGroupList " wheel, docker,wheel, uucp " parsed_groups
[[ "${parsed_groups[*]}" == "wheel docker uucp" ]]
expect_failure parseUserGroupList "" parsed_groups
expect_failure parseUserGroupList "wheel,,docker" parsed_groups
expect_failure parseUserGroupList "wheel,bad group" parsed_groups

CONFIG_USER="labo"
CONFIG_USER_GROUPS_TO_ADD="wheel,docker,uucp"
command_log="${TEST_TMP}/commands.log"

isNormalUser() {
    return 0
}
checkCommand() {
    return 0
}
id() {
    printf 'labo wheel docker\n'
}
getent() {
    [[ "$2" != "missing" ]]
}
usermod() {
    printf 'usermod %s\n' "$*" >>"${command_log}"
}

addUserToGroups >/dev/null
grep -qxF 'usermod --append --groups uucp -- labo' "${command_log}"

: >"${command_log}"
CONFIG_USER_GROUPS_TO_ADD="wheel,docker"
addUserToGroups >/dev/null
[[ ! -s "${command_log}" ]]

CONFIG_USER_GROUPS_TO_ADD="wheel,missing"
expect_failure addUserToGroups

sudoers_dir="${TEST_TMP}/sudoers.d"
visudo_log="${TEST_TMP}/visudo.log"
mkdir -p -- "${sudoers_dir}"

chown() {
    return 0
}
visudo() {
    printf 'visudo %s\n' "$*" >>"${visudo_log}"
    [[ "${FAIL_FULL_VISUDO:-false}" != true || "$1" != "-c" ]]
}

enablePasswordlessSudo "${sudoers_dir}" >/dev/null
sudoers_file="${sudoers_dir}/90-linux-scripts-nopasswd"
grep -qxF 'labo ALL=(ALL:ALL) NOPASSWD: ALL' "${sudoers_file}"
sudoers_mode="$(stat -c '%a' -- "${sudoers_file}")"
[[ "${sudoers_mode}" == 440 ]]
grep -q '^visudo -cf ' "${visudo_log}"
grep -qxF 'visudo -c' "${visudo_log}"

# Reapplying repairs permissions without rejecting the managed file.
chmod 0640 -- "${sudoers_file}"
enablePasswordlessSudo "${sudoers_dir}" >/dev/null
sudoers_mode="$(stat -c '%a' -- "${sudoers_file}")"
[[ "${sudoers_mode}" == 440 ]]

# A failed complete-policy check restores the previous managed file.
chmod 0640 -- "${sudoers_file}"
printf 'labo ALL=(ALL) NOPASSWD: ALL\n' >"${sudoers_file}"
chmod 0440 -- "${sudoers_file}"
FAIL_FULL_VISUDO=true expect_failure \
    enablePasswordlessSudo "${sudoers_dir}"
grep -qxF 'labo ALL=(ALL) NOPASSWD: ALL' "${sudoers_file}"

symbolic_target="${TEST_TMP}/symbolic-target"
printf 'unchanged\n' >"${symbolic_target}"
rm -f -- "${sudoers_file}"
ln -s -- "${symbolic_target}" "${sudoers_file}"
expect_failure enablePasswordlessSudo "${sudoers_dir}"
grep -qxF 'unchanged' "${symbolic_target}"

printf 'init user tests passed\n'
