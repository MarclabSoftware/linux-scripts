#!/usr/bin/env bash

# Failure injection intentionally calls checked helpers in conditional contexts.

# Use generated swap files and redirected rsync roots; never inspect real disks.
# Test doubles replace hardware operations inside the sourced script.
set -Eeuo pipefail
for dependency in rsync mkswap blkid; do
    command -v "${dependency}" >/dev/null || {
        printf 'clone recovery test skipped: requires %s\n' "${dependency}"
        exit 77
    }
done
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
# shellcheck source=src/scripts/clone_disk.sh
source "${REPO_ROOT}/src/scripts/clone_disk.sh"

DST_MOUNT_ROOT="${TEST_TMP}/clone"
DST_DEVICE=/dev/fake-target
DST_PART1=/dev/fake-boot
DST_PART2=/dev/fake-root
BOOT_MOUNT=/boot
swap_source="${TEST_TMP}/swap-source"
swap_destination="${DST_MOUNT_ROOT}${swap_source}"
mkdir -p -- "${TEST_TMP}/root-source${TEST_TMP}" "${TEST_TMP}/boot-source" "${swap_destination%/*}"
printf 'ordinary data\n' >"${TEST_TMP}/root-source/data"
printf 'active swap contents must not be copied\n' >"${TEST_TMP}/root-source${swap_source}"
truncate -s 1M -- "${swap_source}" "${swap_destination}"
chmod 0600 -- "${swap_destination}"
mkswap "${swap_destination}" >/dev/null 2>&1
get_fstab_swap_files() { printf '%s\n' "${swap_source}"; }
get_fstab_swap_devices() { :; }
validate_incremental_target_layout() { :; }
ensure_disk_unmounted() { :; }
fsck_destination_part() { :; }
mount_destination() { :; }
update_destination_config() { :; }
verify_backup() { :; }
findmnt() { return 1; }
rsync() {
    local -a args=("$@")
    local source_index=$(($# - 2))
    # Keep all production filters and options; redirect only the source root.
    if [[ "${args[source_index]}" == / ]]; then
        args[source_index]="${TEST_TMP}/root-source/"
    else
        args[source_index]="${TEST_TMP}/boot-source/"
    fi
    command rsync "${args[@]}" >/dev/null
}

before="$(sha256sum "${swap_destination}")"
perform_incremental_update >/dev/null 2>&1
after="$(sha256sum "${swap_destination}")"
[[ "${before}" == "${after}" ]]
grep -qxF 'ordinary data' "${DST_MOUNT_ROOT}/data"

# A changed source size recreates a valid destination swap file during incrementals.
truncate -s 2M -- "${swap_source}"
perform_incremental_update >/dev/null 2>&1
size="$(stat -c %s "${swap_destination}")"
type="$(blkid -p -s TYPE -o value "${swap_destination}")"
[[ "${size}" == 2097152 && "${type}" == swap ]]
rm -- "${swap_destination}"
recreate_swap >/dev/null 2>&1
type="$(blkid -p -s TYPE -o value "${swap_destination}")"
[[ "${type}" == swap ]]

# A busy filesystem remains visible and makes cleanup fail.
DST_PART2=""
DST_MOUNT_ROOT="${TEST_TMP}/busy-mount"
mkdir -- "${DST_MOUNT_ROOT}"
printf 'keep\n' >"${DST_MOUNT_ROOT}/sentinel"
MOUNTED_BY_SCRIPT=("${DST_MOUNT_ROOT}")
mountpoint() { return 0; }
sync() { :; }
sleep() { :; }
umount() {
    printf '%s\n' "$*" >>"${TEST_TMP}/unmount.calls"
    return 1
}
# shellcheck disable=SC2310
if cleanup >"${TEST_TMP}/cleanup.output" 2>&1; then
    printf 'busy clone mount cleanup reported success\n' >&2
    exit 1
fi
grep -qxF keep "${DST_MOUNT_ROOT}/sentinel"
attempts="$(wc -l <"${TEST_TMP}/unmount.calls")"
[[ "${attempts}" == 3 ]]
if grep -Eq -- '(^|[[:space:]])-[lf]([[:space:]]|$)' "${TEST_TMP}/unmount.calls"; then
    printf 'unsafe clone detach attempted\n' >&2
    exit 1
fi
printf 'Clone recovery tests passed\n'
