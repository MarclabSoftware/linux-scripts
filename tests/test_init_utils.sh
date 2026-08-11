#!/usr/bin/env bash

# Unit checks for provisioning helpers that do not touch the host.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"

# Assert that a helper rejects the supplied arguments.
expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

# These variables are consumed indirectly by checkConfig.
# shellcheck disable=SC2034
sample_value="value"
# shellcheck disable=SC2034
empty_value=""
checkConfig sample_value
expect_failure checkConfig empty_value
expect_failure checkConfig missing_value
expect_failure checkConfig 'invalid-name'

checkCommand bash
expect_failure checkCommand command-that-cannot-exist

expect_failure isNormalUser root
if id nobody >/dev/null 2>&1; then
    isNormalUser nobody
fi

fake_bin="${TEST_TMP}/bin"
service_log="${TEST_TMP}/systemctl.log"
mkdir -p -- "${fake_bin}"
systemctl_file="${fake_bin}/systemctl"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "${service_log}"
} >"${systemctl_file}"
chmod 0755 -- "${systemctl_file}"

PATH="${fake_bin}:${PATH}" enableService example.service false >/dev/null
PATH="${fake_bin}:${PATH}" enableService example.service true >/dev/null
grep -Fx 'enable example.service' "${service_log}" >/dev/null
grep -Fx 'enable --now example.service' "${service_log}" >/dev/null
expect_failure enableService example.service invalid

printf 'init utility tests passed\n'
