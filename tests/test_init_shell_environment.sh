#!/usr/bin/env bash

# Exercise the managed shell files without touching real user homes.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/shell_environment.sh
. "${REPO_ROOT}/src/init/scripts/shell_environment.sh"

# Ownership is not material in this temporary-directory test.
chown() {
    return 0
}

test_home="${TEST_TMP}/home"
current_user="$(id -un)"
mkdir -p -- "${test_home}"
printf '# Existing distribution bashrc\n' >"${test_home}/.bashrc"

configureShellHome "${test_home}" "${current_user}"
configureShellHome "${test_home}" "${current_user}"

grep -Fx '# Existing distribution bashrc' "${test_home}/.bashrc" >/dev/null
include_count="$(grep -cFx \
    ". \"\${HOME}/.config/linux-scripts/bashrc\"" "${test_home}/.bashrc")"
[[ "${include_count}" == 1 ]]
grep -Fx "[[ -r \"\${HOME}/.profile\" ]] && . \"\${HOME}/.profile\"" \
    "${test_home}/.bash_profile" >/dev/null
grep -Fx "[ ! -r \"\${HOME}/.local/bin/env\" ] || . \"\${HOME}/.local/bin/env\"" \
    "${test_home}/.profile" >/dev/null
grep -Fx 'set completion-ignore-case on' "${test_home}/.inputrc" >/dev/null
grep -Fx "alias ls='ls --color=auto'" \
    "${test_home}/.config/linux-scripts/bashrc" >/dev/null
bash -n "${test_home}/.bash_profile" \
    "${test_home}/.config/linux-scripts/bashrc"
dash -n "${test_home}/.profile"

printf 'init shell-environment tests passed\n'
