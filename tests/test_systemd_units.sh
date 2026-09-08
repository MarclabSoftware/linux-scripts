#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SYSTEMD_DIR="${REPO_ROOT}/systemd"

shopt -s nullglob
units=("${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer "${SYSTEMD_DIR}"/*.path)
((${#units[@]} > 0))

if grep -n -F '%h' "${units[@]}"; then
    printf 'system units must use their instance explicitly, not manager %%h\n' >&2
    exit 1
fi

trigger_units=("${SYSTEMD_DIR}"/*@.timer "${SYSTEMD_DIR}"/*@.path)
for trigger_unit in "${trigger_units[@]}"; do
    service_unit="${trigger_unit%.*}.service"
    if [[ ! -f ${service_unit} ]]; then
        printf 'timer/path has no matching service: %s\n' "${trigger_unit}" >&2
        exit 1
    fi
    if grep -q '^Unit=' "${trigger_unit}"; then
        printf 'same-name timer/path has an unnecessary Unit=: %s\n' "${trigger_unit}" >&2
        exit 1
    fi
done

((${#trigger_units[@]} > 0))

instance_units=("${SYSTEMD_DIR}"/*@.*)
for instance_unit in "${instance_units[@]}"; do
    [[ -f ${instance_unit} ]] || continue
    if ! grep -q '^# Instance:' "${instance_unit}" ||
        ! grep -q '^# Example:' "${instance_unit}"; then
        printf 'template lacks instance documentation: %s\n' "${instance_unit}" >&2
        exit 1
    fi
done

# Parse real unit contents with systemd itself, in a synthetic installation.
# No unit is started; missing host packages are represented by dummy binaries.
command -v systemd-analyze >/dev/null || {
    printf 'systemd parser test skipped: systemd-analyze is unavailable\n'
    exit 77
}
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
unit_dir="${TEST_TMP}/etc/systemd/system"
mkdir -p -- "${unit_dir}"
cp -- "${units[@]}" "${unit_dir}/"
for unit in sysinit.target basic.target shutdown.target sockets.target timers.target paths.target network.target network-online.target; do
    printf '[Unit]\nDescription=Synthetic dependency\n' >"${unit_dir}/${unit}"
done
for unit in docker.service test.service; do
    printf '[Service]\nType=oneshot\nExecStart=/usr/bin/true\n' >"${unit_dir}/${unit}"
done
executables=(/usr/bin/true)
for unit in "${units[@]}"; do
    while IFS= read -r line; do
        executable="${line#*=}"
        executable="${executable#-}"
        executable="${executable%% *}"
        executable="${executable//%i/test}"
        [[ "${executable}" == /* ]] || continue
        executables+=("${executable}")
    done < <(grep '^Exec' "${unit}" || true)
done
for executable in "${executables[@]}"; do
    mkdir -p -- "${TEST_TMP}${executable%/*}"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"${TEST_TMP}${executable}"
    chmod 0755 -- "${TEST_TMP}${executable}"
done
# Also check that the one repo-owned libexec path names a shipped executable.
[[ -x "${REPO_ROOT}/src/scripts/unbound_update_root_hints.sh" ]]
verify_units=()
for unit in "${units[@]}"; do
    name="${unit##*/}"
    verify_units+=("${name/@./@test.}")
done
SYSTEMD_LOG_LEVEL=warning systemd-analyze --root="${TEST_TMP}" --man=no verify "${verify_units[@]}"
printf 'systemd unit structure and parser tests passed\n'
