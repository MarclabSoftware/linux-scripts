#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SYSTEMD_DIR="${REPO_ROOT}/systemd"

if grep -R -n -F '%h' "${SYSTEMD_DIR}"; then
    printf 'system units must use their instance explicitly, not manager %%h\n' >&2
    exit 1
fi

shopt -s nullglob
trigger_units=("${SYSTEMD_DIR}"/*@.timer "${SYSTEMD_DIR}"/*@.path)
for trigger_unit in "${trigger_units[@]}"; do
    if grep -q '^Unit=' "${trigger_unit}"; then
        printf 'same-name timer/path has an unnecessary Unit=: %s\n' "${trigger_unit}" >&2
        exit 1
    fi
done

((${#trigger_units[@]} > 0))
