#!/usr/bin/env bash

# Runtime loader embedded in the text artifact produced by build.sh.
#
# build.sh appends one call to linux_init_main followed by a Base64 heredoc.
# Keeping decoding here and packaging there makes the deployment format easy
# to inspect without maintaining two independent execution paths.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

LINUX_INIT_WORK_DIR=""

linux_init_die() {
    printf 'linux-init: %s\n' "$*" >&2
    exit 1
}

linux_init_cleanup() {
    local temporary_parent

    [[ -n "${LINUX_INIT_WORK_DIR}" ]] || return 0
    temporary_parent="${LINUX_INIT_WORK_DIR%/*}"
    [[ "${LINUX_INIT_WORK_DIR}" == "${temporary_parent}"/linux-init.* ]] || {
        printf 'linux-init: refusing unsafe cleanup path: %s\n' \
            "${LINUX_INIT_WORK_DIR}" >&2
        return 1
    }
    rm -rf -- "${LINUX_INIT_WORK_DIR}"
}

linux_init_validate_archive_paths() {
    local archive="$1"
    local entry listing_file
    local found_entry=false

    listing_file="${LINUX_INIT_WORK_DIR}/archive.list"
    if ! TAR_OPTIONS="" GZIP="" tar -tzf "${archive}" \
        >"${listing_file}"; then
        printf 'linux-init: cannot list the embedded archive\n' >&2
        return 1
    fi

    while IFS= read -r entry; do
        found_entry=true
        case "${entry}" in
            /* | ../* | */../* | */..)
                printf 'linux-init: unsafe archive path: %s\n' \
                    "${entry}" >&2
                return 1
                ;;
            *) ;;
        esac
    done <"${listing_file}"
    [[ "${found_entry}" == true ]] || {
        printf 'linux-init: embedded archive is empty\n' >&2
        return 1
    }
}

linux_init_run_provisioner() {
    local init_script="$1"
    shift
    local command_status tty_fd
    local -a provisioner_command=()

    # Syntax-only commands need no privilege escalation. Preflight is
    # read-only but audits protected account files and therefore runs as root.
    if [[ "${1:-}" == "--check-config" ||
        "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        provisioner_command=(
            env BASH_ENV=/dev/null
            bash --noprofile --norc "${init_script}" "$@"
        )
    elif ((EUID == 0)); then
        provisioner_command=(
            env BASH_ENV=/dev/null
            bash --noprofile --norc "${init_script}" "$@"
        )
    elif command -v sudo >/dev/null 2>&1; then
        provisioner_command=(
            sudo -- env BASH_ENV=/dev/null
            bash --noprofile --norc "${init_script}" "$@"
        )
    else
        linux_init_die "run as root or install sudo"
    fi

    # The inner Bash receives its source through a heredoc. Reconnect commands
    # to the controlling terminal when one exists so sudo and package-manager
    # prompts remain interactive after a copy/paste deployment.
    if { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        if "${provisioner_command[@]}" <&"${tty_fd}"; then
            command_status=0
        else
            command_status=$?
        fi
        exec {tty_fd}>&-
        return "${command_status}"
    fi
    "${provisioner_command[@]}"
}

linux_init_main() {
    if (($# < 1)) ||
        [[ ! "$1" =~ ^[[:xdigit:]]{64}$ ]]; then
        linux_init_die "invalid embedded archive checksum"
    fi

    local expected_checksum="$1"
    shift
    local command_name actual_checksum temporary_parent validation_status
    local preflight_status
    local archive_file payload_dir init_script

    for command_name in base64 bash env mkdir mktemp readlink rm sha256sum tar; do
        command -v -- "${command_name}" >/dev/null 2>&1 ||
            linux_init_die "required command not found: ${command_name}"
    done

    temporary_parent="$(readlink -f -- "${TMPDIR:-/tmp}")" ||
        linux_init_die "cannot resolve the temporary directory"
    [[ -d "${temporary_parent}" && -w "${temporary_parent}" ]] ||
        linux_init_die \
            "temporary directory is not writable: ${temporary_parent}"

    LINUX_INIT_WORK_DIR="$(mktemp -d -- \
        "${temporary_parent%/}/linux-init.XXXXXXXXXX")" ||
        linux_init_die "cannot create a temporary directory"
    readonly LINUX_INIT_WORK_DIR
    trap linux_init_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    archive_file="${LINUX_INIT_WORK_DIR}/payload.tar.gz"
    payload_dir="${LINUX_INIT_WORK_DIR}/payload"
    mkdir -m 0700 -- "${payload_dir}"

    if ! base64 --decode >"${archive_file}"; then
        linux_init_die "cannot decode the embedded archive"
    fi
    actual_checksum="$(sha256sum -- "${archive_file}")" ||
        linux_init_die "cannot checksum the embedded archive"
    actual_checksum="${actual_checksum%% *}"
    [[ "${actual_checksum}" == "${expected_checksum,,}" ]] ||
        linux_init_die \
            "embedded archive checksum mismatch; paste or file is corrupted"

    set +e
    linux_init_validate_archive_paths "${archive_file}"
    validation_status=$?
    set -e
    ((validation_status == 0)) || exit "${validation_status}"
    if ! TAR_OPTIONS="" GZIP="" tar -xzf "${archive_file}" \
        -C "${payload_dir}" --no-same-owner --no-same-permissions; then
        linux_init_die "cannot extract the embedded archive"
    fi

    init_script="${payload_dir}/init.sh"
    [[ -f "${init_script}" && -r "${init_script}" &&
        ! -L "${init_script}" ]] ||
        linux_init_die "embedded init.sh is missing or unsafe"
    [[ -f "${payload_dir}/init.env" &&
        ! -L "${payload_dir}/init.env" ]] ||
        linux_init_die "embedded init.env is missing or unsafe"

    if (($# == 0)); then
        printf 'Validating host prerequisites before provisioning\n'
        set +e
        linux_init_run_provisioner "${init_script}" --preflight
        preflight_status=$?
        set -e
        if ((preflight_status != 0)); then
            linux_init_die "preflight failed; provisioning was not started"
        fi
        printf 'Preflight passed; starting provisioning\n'
        linux_init_run_provisioner "${init_script}"
    else
        linux_init_run_provisioner "${init_script}" "$@"
    fi
}
