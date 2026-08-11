#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT
cd -- "${REPO_ROOT}"

die() {
    printf 'check: %s\n' "$*" >&2
    exit 1
}

for command_name in bash cat checkbashisms dash git gitleaks grep shellcheck shfmt; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "repository root not found: ${REPO_ROOT}"

# Process substitution keeps filenames NUL-safe; Git validity is checked above.
# shellcheck disable=SC2312
mapfile -d '' -t candidates < <(
    git ls-files -z --cached --others --exclude-standard -- '*.sh'
)
scripts=()
for file in "${candidates[@]}"; do
    [[ -f ${file} ]] && scripts+=("${file}")
done
((${#scripts[@]} > 0)) || die "no shell scripts found"

printf 'Checking %d shell scripts\n' "${#scripts[@]}"
shellcheck --external-sources --severity=style --enable=all "${scripts[@]}"
shfmt -d "${scripts[@]}"

for file in "${scripts[@]}"; do
    IFS= read -r shebang <"${file}" || shebang=
    case ${shebang} in
        '#!/bin/sh')
            dash -n "${file}"
            checkbashisms --posix "${file}"
            ;;
        *bash*)
            bash -n "${file}"
            ;;
        *)
            die "unsupported or missing shebang: ${file}"
            ;;
    esac
done

if grep -nHE '[[:blank:]]+$' "${scripts[@]}"; then
    die "trailing whitespace found"
fi
if grep -l $'\r$' "${scripts[@]}"; then
    die "CRLF line endings found"
fi

# shellcheck disable=SC2312
mapfile -d '' -t candidates < <(
    git ls-files -z --cached --others --exclude-standard -- '*.env.example'
)
env_examples=()
for file in "${candidates[@]}"; do
    [[ -f ${file} ]] && env_examples+=("${file}")
done
for file in "${env_examples[@]}"; do
    bash -n "${file}"
done

shopt -s nullglob
tests=(tests/test_*.sh)
((${#tests[@]} > 0)) || die "no tests found"
printf 'Running %d tests\n' "${#tests[@]}"
for test_file in "${tests[@]}"; do
    bash "${test_file}"
done

{
    for file in "${scripts[@]}" "${env_examples[@]}"; do
        printf '\n# file: %s\n' "${file}"
        cat -- "${file}"
    done
} | gitleaks stdin --no-banner --redact
gitleaks git --no-banner --redact .

printf 'All checks passed\n'
