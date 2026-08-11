#!/usr/bin/env bash

# Exercise additive and idempotent .nanorc configuration without touching HOME.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/nano_syntax_highlighting.sh
. "${REPO_ROOT}/src/init/scripts/nano_syntax_highlighting.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

owner="$(id -un)"
group="$(id -gn)"
config_file="${TEST_TMP}/.nanorc"
printf 'set tabsize 4\n' >"${config_file}"

configureNanoFile "${config_file}" "${owner}" "${group}" >/dev/null
configureNanoFile "${config_file}" "${owner}" "${group}" >/dev/null

grep -Fx 'set tabsize 4' "${config_file}" >/dev/null
include_count="$(grep -cxF 'include "/usr/share/nano/*.nanorc"' "${config_file}")"
linenumbers_count="$(grep -cxF 'set linenumbers' "${config_file}")"
config_mode="$(stat -c '%a' "${config_file}")"
[[ "${include_count}" == 1 ]]
[[ "${linenumbers_count}" == 1 ]]
[[ "${config_mode}" == 644 ]]

symlink_file="${TEST_TMP}/linked.nanorc"
ln -s -- "${config_file}" "${symlink_file}"
expect_failure configureNanoFile "${symlink_file}" "${owner}" "${group}"

printf 'Nano configuration tests passed\n'
