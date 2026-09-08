#!/usr/bin/env bash

# Every public entry point must describe its CLI without running its operation.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
mkdir -p -- "${TEST_TMP}/scripts/media"
# The copied scripts have no private sidecars. Never source the user's config.
for script in "${REPO_ROOT}/src/scripts/"*.sh "${REPO_ROOT}/src/scripts/media/"*.sh; do
    relative="${script#"${REPO_ROOT}/src/scripts/"}"
    cp -- "${script}" "${TEST_TMP}/scripts/${relative}"
done
for script in "${TEST_TMP}/scripts/"*.sh "${TEST_TMP}/scripts/media/"*.sh; do
    [[ "${script##*/}" != media_common.sh ]] || continue
    bash "${script}" --help >"${TEST_TMP}/help" 2>"${TEST_TMP}/error"
    grep -qi 'usage:' "${TEST_TMP}/help"
done
printf 'standalone help tests passed\n'
