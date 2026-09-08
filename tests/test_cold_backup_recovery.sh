#!/usr/bin/env bash

# Failure injection intentionally calls checked helpers in conditional contexts.

# Simulate disk failures without mounting, deleting, or reading host data.
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export COLD_TEST_ROOT="${TEST_TMP}" COLD_BACKUP_ENV_FILE="${TEST_TMP}/cold.env"
mkdir -p -- "${TEST_TMP}/bin" "${TEST_TMP}/source/nested" "${TEST_TMP}/home"
cat >"${COLD_BACKUP_ENV_FILE}" <<EOF
COLD_BACKUP_SOURCE_MOUNT='${TEST_TMP}/source'
COLD_BACKUP_NVME_UUID=nvme-test
COLD_BACKUP_NVME_MOUNT='${TEST_TMP}/nvme'
COLD_BACKUP_NVME_DATA_SOURCE='${TEST_TMP}/source/nested/'
COLD_BACKUP_HDD_UUID=hdd-test
COLD_BACKUP_HDD_MOUNT='${TEST_TMP}/hdd'
COLD_BACKUP_HDD_DATA_SOURCE='${TEST_TMP}/source/'
COLD_BACKUP_HOME_SOURCE='${TEST_TMP}/home'
COLD_BACKUP_LOCK_FILE='${TEST_TMP}/backup.lock'
EOF
chmod 0600 -- "${COLD_BACKUP_ENV_FILE}"
cat >"${TEST_TMP}/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mount_point="" output=""
while (($#)); do
    case "$1" in
        -M) mount_point="$2"; shift ;;
        -o) output="$2"; shift ;;
        *) ;;
    esac
    shift
done
if [[ "${mount_point}" == "${COLD_TEST_ROOT}/source" ]]; then
    [[ "${COLD_FAIL_SOURCE:-false}" != true ]] || exit 1
else
    [[ "${COLD_FAIL_TARGET:-false}" != true ]] || exit 1
fi
if [[ "${output}" == UUID ]]; then
    printf '%s-test\n' "${mount_point##*/}"
fi
EOF
cat >"${TEST_TMP}/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${COLD_TEST_ROOT}/rsync.calls"
[[ "${COLD_FAIL_NVME:-false}" != true || "${*: -1}" != */nvme/* ]] || exit 23
EOF
cat >"${TEST_TMP}/bin/blkid" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
for command_name in mount umount sync pkill sleep; do
    cat >"${TEST_TMP}/bin/${command_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${0##*/}" "$*" >>"${COLD_TEST_ROOT}/mutations.calls"
[[ "${0##*/}" != umount || "${*: -1}" != */busy ]] || exit 1
EOF
done
chmod 0700 -- "${TEST_TMP}/bin/"*
export PATH="${TEST_TMP}/bin:${PATH}"

(
    # Exact mount, trailing slash and descendants must all refuse --delete.
    # shellcheck source=src/scripts/cold_backup.sh
    source "${REPO_ROOT}/src/scripts/cold_backup.sh"
    export COLD_FAIL_SOURCE=true
    for source_path in "${SRC_DATA_MOUNT}" "${SRC_DATA_MOUNT}/" "${SRC_DATA_MOUNT}/nested"; do
        # shellcheck disable=SC2310
        if run_rsync "${source_path}" "${TEST_TMP}/unwanted/destination" test >"${TEST_TMP}/source.output" 2>&1; then
            printf 'unmounted source accepted: %s\n' "${source_path}" >&2
            exit 1
        fi
        grep -Fq 'Refusing rsync --delete' "${TEST_TMP}/source.output"
    done
    [[ ! -e "${TEST_TMP}/rsync.calls" && ! -e "${TEST_TMP}/unwanted" ]]
)

if COLD_FAIL_NVME=true "${REPO_ROOT}/src/scripts/cold_backup.sh" --dry-run >"${TEST_TMP}/failure.output" 2>&1; then
    printf 'failed NVMe backup reported success\n' >&2
    exit 1
fi
grep -qxF "${TEST_TMP}/hdd/data/" "${TEST_TMP}/rsync.calls"
grep -qxF "${TEST_TMP}/hdd/home/" "${TEST_TMP}/rsync.calls"
[[ ! -e "${TEST_TMP}/mutations.calls" && ! -e "${TEST_TMP}/backup.lock" ]]
[[ ! -e "${TEST_TMP}/nvme" && ! -e "${TEST_TMP}/hdd" ]]

rm -- "${TEST_TMP}/rsync.calls"
if COLD_FAIL_TARGET=true "${REPO_ROOT}/src/scripts/cold_backup.sh" --dry-run >"${TEST_TMP}/unmounted.output" 2>&1; then
    printf 'dry-run accepted an unmounted target\n' >&2
    exit 1
fi
grep -Fq 'no mount was attempted' "${TEST_TMP}/unmounted.output"
[[ ! -e "${TEST_TMP}/rsync.calls" && ! -e "${TEST_TMP}/mutations.calls" ]]

# Failed unmount is a failed run; cleanup still attempts the remaining drive.
set +e
(
    set -e
    # shellcheck source=src/scripts/cold_backup.sh
    source "${REPO_ROOT}/src/scripts/cold_backup.sh"
    MOUNT_POINTS_TO_UNMOUNT=("${TEST_TMP}/ready" "${TEST_TMP}/busy")
    cleanup
) >"${TEST_TMP}/cleanup.output" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]]
grep -qxF "umount ${TEST_TMP}/ready" "${TEST_TMP}/mutations.calls"
busy_attempts="$(grep -cFx "umount ${TEST_TMP}/busy" "${TEST_TMP}/mutations.calls")"
[[ "${busy_attempts}" == 3 ]]
if grep -Eq 'umount .*-(l|f)' "${TEST_TMP}/mutations.calls"; then
    printf 'cleanup attempted an unsafe detach\n' >&2
    exit 1
fi
printf 'Cold backup recovery tests passed\n'
