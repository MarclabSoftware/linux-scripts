#!/bin/bash

###############################################################################
# USB Device Scanner
#
# This script scans and lists all USB devices connected to the system,
# displaying their device paths and serial numbers. It uses parallel processing
# for improved performance on systems with multiple cores.
#
# The script implements error handling and skips irrelevant devices like
# bus entries. It's particularly useful for system administrators and
# developers who need to inventory USB devices.
#
# Author: LaboDJ
# Version: 1.1
# Last Updated: 2026/07/28
###############################################################################

# Set strict mode to catch errors
set -euo pipefail

# Function to process each device
process_device() {
    local sysdevpath="$1"
    local syspath="${sysdevpath%/dev}"
    local devname
    local properties

    # Get device name more efficiently
    devname=$(udevadm info -q name -p "${syspath}") || return

    # Skip bus devices
    [[ "${devname}" == bus/* ]] && return

    # Get properties in a single call
    properties=$(udevadm info -q property --export -p "${syspath}") || return

    # Extract ID_SERIAL using grep instead of eval
    local serial
    serial=$(echo "${properties}" | grep '^ID_SERIAL=' | cut -d= -f2)

    # Skip if no serial number is found
    [[ -z "${serial}" ]] && return

    echo "/dev/${devname} - ${serial}"
}

export -f process_device

# Use xargs to process in parallel
parallel_jobs=$(nproc)
find /sys/bus/usb/devices/usb*/ -name dev -print0 \
    | xargs -0 -I {} -P "${parallel_jobs}" bash -c 'process_device "$@"' _ {}
