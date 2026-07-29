#!/usr/bin/env bash

# USB Device Scanner
# Version: 2.0.0
# Updated: 2026-07-29
#
# Lists device nodes and stable serial identifiers for attached USB devices.
# Device metadata is queried concurrently because udevadm calls are independent.

set -euo pipefail

# Function to process each device
process_device() {
    local sysdevpath="$1"
    local syspath="${sysdevpath%/dev}"
    local devname
    local properties

    devname=$(udevadm info -q name -p "${syspath}") || return

    # Skip bus devices
    [[ "${devname}" == bus/* ]] && return

    # Get properties in a single call
    properties=$(udevadm info -q property --export -p "${syspath}") || return

    local serial
    serial=$(grep '^ID_SERIAL=' <<<"${properties}" | cut -d= -f2-)

    # Skip if no serial number is found
    [[ -z "${serial}" ]] && return

    printf '/dev/%s - %s\n' "${devname}" "${serial}"
}

export -f process_device

parallel_jobs=$(nproc)
find /sys/bus/usb/devices/usb*/ -name dev -print0 |
    xargs -0 -r -I {} -P "${parallel_jobs}" bash -c 'process_device "$@"' _ {}
