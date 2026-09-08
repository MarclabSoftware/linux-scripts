#!/usr/bin/env bash

# Repository checks. Use --static/--tests to avoid the optional secret scans.
# No arguments also scans committable files, staged content and Git history.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT
cd -- "${REPO_ROOT}"

die() {
    printf 'check: %s\n' "$*" >&2
    exit 1
}

# Keep NUL-delimited filenames and check the producer even after partial output.
read_repository_files() {
    local listing_fd listing_pid

    # The producer status is collected explicitly by wait below.
    # shellcheck disable=SC2312
    exec {listing_fd}< <(git ls-files -z --cached --others --exclude-standard "$@")
    listing_pid=$!
    mapfile -d '' -t candidates <&"${listing_fd}" || die 'could not read repository file list'
    exec {listing_fd}<&-
    wait "${listing_pid}" || die 'could not enumerate repository files'
}

# Selectors can be combined. No arguments preserves the complete release check.
run_static=false
run_tests=false
run_secrets=false
if (($# == 0)); then
    run_static=true
    run_tests=true
    run_secrets=true
fi
for option in "$@"; do
    case "${option}" in
        --static) run_static=true ;;
        --tests) run_tests=true ;;
        --secrets) run_secrets=true ;;
        -h | --help)
            printf '%s\n' \
                'Usage: ./check.sh [--static] [--tests] [--secrets]' \
                'No arguments: all checks. Selectors can be combined.' \
                '--static   Lint, syntax, formatting and executable modes.' \
                '--tests    Run all tests; report PASS, FAIL and SKIP (exit 77).' \
                '--secrets  Scan committable files, staged changes and Git history.'
            exit 0
            ;;
        *) die "unknown option: ${option}; see --help" ;;
    esac
done

commands=(bash)
[[ "${run_static}" != true ]] || commands+=(checkbashisms dash git grep shellcheck shfmt)
[[ "${run_secrets}" != true ]] || commands+=(cat git gitleaks)
for command_name in "${commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command not found: ${command_name}"
done
if [[ "${run_static}" == true || "${run_secrets}" == true ]]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "repository root not found: ${REPO_ROOT}"
fi

if [[ "${run_static}" == true ]]; then
    read_repository_files -- '*.sh'
    scripts=()
    for file in "${candidates[@]}"; do
        [[ ! -L "${file}" ]] || die "symbolic-link input rejected: ${file}"
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

    # Git executable bits are part of the release: a fresh clone must be directly
    # usable even when the current worktree happens to have permissive modes.
    entrypoints=(build.sh check.sh src/bootstrap.sh src/init/init.sh)
    for file in "${scripts[@]}"; do
        case ${file} in
            src/scripts/media/media_common.sh | src/init/* | tests/*) ;;
            src/scripts/*) entrypoints+=("${file}") ;;
            *) ;;
        esac
    done
    for file in "${entrypoints[@]}"; do
        [[ -x ${file} ]] || die "entry point is not executable: ${file}"
        # Untracked scripts have no index entry yet; their filesystem mode is
        # checked above and Git will record it when they are added.
        index_entry=$(git ls-files -s -- "${file}")
        case ${index_entry} in
            "" | 100755\ *) ;;
            *) die "entry point is not executable in Git: ${file}" ;;
        esac
    done

    if grep -nHE '[[:blank:]]+$' "${scripts[@]}"; then
        die "trailing whitespace found"
    fi
    if grep -l $'\r$' "${scripts[@]}"; then
        die "CRLF line endings found"
    fi

    read_repository_files -- '*.env.example'
    env_examples=()
    for file in "${candidates[@]}"; do
        [[ ! -L "${file}" ]] || die "symbolic-link input rejected: ${file}"
        [[ -f ${file} ]] && env_examples+=("${file}")
    done
    for file in "${env_examples[@]}"; do
        bash -n "${file}"
    done

fi

if [[ "${run_tests}" == true ]]; then
    shopt -s nullglob
    tests=(tests/test_*.sh)
    ((${#tests[@]} > 0)) || die "no tests found"
    printf 'Running %d tests\n' "${#tests[@]}"
    passed=0
    failed=0
    skipped=0
    for test_file in "${tests[@]}"; do
        if bash "${test_file}"; then
            printf 'PASS %s\n' "${test_file}"
            passed=$((passed + 1))
        else
            status=$?
            if ((status == 77)); then
                printf 'SKIP %s\n' "${test_file}"
                skipped=$((skipped + 1))
            else
                printf 'FAIL %s (exit %d)\n' "${test_file}" "${status}" >&2
                failed=$((failed + 1))
            fi
        fi
    done
    printf 'Tests: %d passed, %d failed, %d skipped\n' "${passed}" "${failed}" "${skipped}"
    ((failed == 0)) || die 'test failures'
fi

if [[ "${run_secrets}" == true ]]; then

    # Scan every file that Git could commit, including untracked units and
    # documentation, while naturally excluding ignored private inventories.
    read_repository_files
    repository_files=()
    for file in "${candidates[@]}"; do
        [[ ! -L "${file}" ]] || die "symbolic-link input rejected: ${file}"
        [[ -f ${file} ]] && repository_files+=("${file}")
    done

    {
        for file in "${repository_files[@]}"; do
            printf '\n# file: %s\n' "${file}"
            cat -- "${file}"
        done
    } | gitleaks stdin --no-banner --redact
    git diff --cached --no-ext-diff --no-textconv |
        gitleaks stdin --no-banner --redact
    gitleaks git --no-banner --redact .

fi

printf 'Selected checks passed\n'
