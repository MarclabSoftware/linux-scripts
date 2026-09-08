#!/usr/bin/env bash

# Exercise check selection and aggregation against synthetic tests only.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
mkdir -p -- "${TEST_TMP}/tests" "${TEST_TMP}/bin"
cp -- "${REPO_ROOT}/check.sh" "${TEST_TMP}/check.sh"
# Any unselected checker would fail this test if invoked.
for checker in git shellcheck shfmt gitleaks; do
    printf '%s\n' '#!/bin/sh' 'exit 99' >"${TEST_TMP}/bin/${checker}"
    chmod 0755 -- "${TEST_TMP}/bin/${checker}"
done
printf '%s\n' '#!/bin/sh' 'exit 0' >"${TEST_TMP}/tests/test_a.sh"
printf '%s\n' '#!/bin/sh' 'exit 77' >"${TEST_TMP}/tests/test_b.sh"
PATH="${TEST_TMP}/bin:${PATH}" bash "${TEST_TMP}/check.sh" --tests >"${TEST_TMP}/output"
grep -qxF 'Tests: 1 passed, 0 failed, 1 skipped' "${TEST_TMP}/output"
printf '%s\n' '#!/bin/sh' 'exit 23' >"${TEST_TMP}/tests/test_a.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' >"${TEST_TMP}/tests/test_c.sh"
if PATH="${TEST_TMP}/bin:${PATH}" bash "${TEST_TMP}/check.sh" --tests >"${TEST_TMP}/output" 2>&1; then
    printf 'check accepted a failed test\n' >&2
    exit 1
fi
grep -qxF 'Tests: 1 passed, 1 failed, 1 skipped' "${TEST_TMP}/output"
if bash "${TEST_TMP}/check.sh" --unknown >/dev/null 2>&1; then
    exit 1
fi
PATH="${TEST_TMP}/bin:${PATH}" bash "${TEST_TMP}/check.sh" --help >/dev/null
printf 'check selector tests passed\n'

# Synthetic Git output only: never enumerate or scan the real repository.
for checker in shellcheck shfmt checkbashisms; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"${TEST_TMP}/bin/${checker}"
    chmod 0755 -- "${TEST_TMP}/bin/${checker}"
done
mkdir -p -- "${TEST_TMP}/src/init"
for entry in build.sh src/bootstrap.sh src/init/init.sh; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"${TEST_TMP}/${entry}"
    chmod 0755 -- "${TEST_TMP}/${entry}"
done
# A newline in a filename must survive enumeration unchanged.
example=$'sample with\nnewline.env.example'
printf '%s\n' 'EXAMPLE=value' >"${TEST_TMP}/${example}"
cat >"${TEST_TMP}/bin/git" <<'MOCK'
#!/bin/sh
case "$1" in
    rev-parse) exit 0 ;;
    ls-files)
        case "$2" in
            -s) exit 0 ;;
        esac
        case "$*" in
            *'*.env.example')
                printf 'sample with\nnewline.env.example\000'
                [ "${FAIL_LISTING:-}" != examples ] || exit 23
                ;;
            *'*.sh')
                printf 'build.sh\000'
                [ "${FAIL_LISTING:-}" != scripts ] || exit 23
                ;;
            *)
                printf 'build.sh\000'
                [ "${FAIL_LISTING:-}" != all ] || exit 23
                ;;
        esac
        ;;
    *) exit 99 ;;
esac
MOCK
chmod 0755 -- "${TEST_TMP}/bin/git"
PATH="${TEST_TMP}/bin:${PATH}" bash "${TEST_TMP}/check.sh" --static >"${TEST_TMP}/output"
grep -qxF 'Selected checks passed' "${TEST_TMP}/output"
for failure in scripts examples all; do
    selector=--static
    [[ "${failure}" != all ]] || selector=--secrets
    if FAIL_LISTING="${failure}" PATH="${TEST_TMP}/bin:${PATH}" \
        bash "${TEST_TMP}/check.sh" "${selector}" >"${TEST_TMP}/output" 2>&1; then
        printf 'check accepted a partial %s listing\n' "${failure}" >&2
        exit 1
    fi
    grep -qxF 'check: could not enumerate repository files' "${TEST_TMP}/output"
done
# Prove that the unusual filename was actually checked, not silently skipped.
printf '%s\n' 'if' >"${TEST_TMP}/${example}"
if PATH="${TEST_TMP}/bin:${PATH}" bash "${TEST_TMP}/check.sh" --static >"${TEST_TMP}/output" 2>&1; then
    printf 'check skipped an invalid example with a newline in its name\n' >&2
    exit 1
fi
printf 'check enumeration tests passed\n'
