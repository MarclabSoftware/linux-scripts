#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SYSTEMD_DIR="${REPO_ROOT}/systemd"

shopt -s nullglob
units=("${SYSTEMD_DIR}"/*)
((${#units[@]} > 0))

if grep -R -n -F '%h' "${SYSTEMD_DIR}"; then
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
    if ! grep -q '^# Instance:' "${instance_unit}" ||
        ! grep -q '^# Example:' "${instance_unit}"; then
        printf 'template lacks instance documentation: %s\n' "${instance_unit}" >&2
        exit 1
    fi
done
