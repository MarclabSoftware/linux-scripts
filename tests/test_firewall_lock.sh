#!/usr/bin/env bash

# Run as root or inside a disposable user namespace; use only a private temp tree.
set -Eeuo pipefail
((EUID == 0)) || {
    printf 'firewall lock test skipped: requires root or a user namespace\n'
    exit 77
}
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
holder=""
cleanup_test() {
    if [[ -n "${holder}" ]]; then
        kill -TERM "${holder}" 2>/dev/null || true
        wait "${holder}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_TMP}"
}
trap cleanup_test EXIT
export IP_BLOCKER_ENV_FILE=/nonexistent IP_BLOCKER_LOCK_DIR="${TEST_TMP}/lock" IP_BLOCKER_LIST_DIR="${TEST_TMP}/lists"
export IP_BLOCKER_SCRIPT="${REPO_ROOT}/src/scripts/ip_blocker.sh"
mkfifo -- "${TEST_TMP}/release"
for signal in TERM KILL; do
    bash -c 'source "${IP_BLOCKER_SCRIPT}"; setup_temp_dir_and_traps; printf ready >"$1/ready"; read -r released <"$1/release"' _ "${TEST_TMP}" \
        >"${TEST_TMP}/holder.output" 2>&1 &
    holder=$!
    for _ in {1..100}; do
        [[ ! -f "${TEST_TMP}/ready" ]] || break
        sleep 0.02
    done
    [[ -f "${TEST_TMP}/ready" ]]
    if bash -c 'source "${IP_BLOCKER_SCRIPT}"; setup_temp_dir_and_traps' >"${TEST_TMP}/contender.output" 2>&1; then
        printf 'concurrent firewall instance acquired the lock\n' >&2
        exit 1
    fi
    grep -Fq 'Script is already running' "${TEST_TMP}/contender.output"
    kill -"${signal}" "${holder}"
    wait "${holder}" 2>/dev/null || true
    holder=""
    [[ -f "${IP_BLOCKER_LOCK_DIR}/lock" ]]
    bash -c 'source "${IP_BLOCKER_SCRIPT}"; setup_temp_dir_and_traps' >"${TEST_TMP}/next.output" 2>&1
    rm -- "${TEST_TMP}/ready"
done
printf '%s\n' "$$" >"${IP_BLOCKER_LOCK_DIR}/pid"
if bash -c 'source "${IP_BLOCKER_SCRIPT}"; setup_temp_dir_and_traps' >"${TEST_TMP}/legacy.output" 2>&1; then
    printf 'live legacy PID lock was ignored\n' >&2
    exit 1
fi
grep -Fq 'An older script is still running' "${TEST_TMP}/legacy.output"
printf 'Firewall lock tests passed\n'
