#!/usr/bin/env bash

# Exercise complete receiver/restore transactions with synthetic SQLite data
# and fake Docker commands. No running service or real backup is accessed.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
command -v sqlite3 >/dev/null || {
    printf 'vaultwarden recovery tests skipped: sqlite3 is unavailable\n'
    exit 77
}
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
mkdir -- "${TEST_TMP}/bin"

cat >"${TEST_TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${PROBE_ROOT}/commands"
fail_once() {
    if [[ ! -e "${PROBE_ROOT}/failed-$1" ]]; then
        : >"${PROBE_ROOT}/failed-$1"
        exit 45
    fi
}
case "$1" in
    ps)
        [[ "${PROBE_MODE}" != receive_error ]] || exit 42
        [[ "${PREVIOUS_RUNNING}" != true ]] || printf 'fixture-container\n'
        ;;
    inspect)
        case "${PROBE_MODE}" in
            inspect_error) fail_once inspect ;;
            rollback_inspect_error) exit 46 ;;
            health_error | health_timeout)
                if [[ ! -e "${PROBE_ROOT}/failed-health" ]]; then
                    : >"${PROBE_ROOT}/failed-health"
                    if [[ "${PROBE_MODE}" == health_timeout ]]; then
                        printf 'starting\n'
                    else
                        printf 'unhealthy\n'
                    fi
                    exit 0
                fi
                ;;
            *) ;;
        esac
        printf 'healthy\n'
        ;;
    compose)
        case "${6:-}" in
            ps)
                if [[ " $* " == *' --status running '* ]]; then
                    [[ "${PREVIOUS_RUNNING}" != true ]] || printf 'fixture-container\n'
                elif [[ "${PROBE_MODE}" == empty_container && ! -e "${PROBE_ROOT}/failed-empty" ]]; then
                    : >"${PROBE_ROOT}/failed-empty"
                else
                    [[ "${PROBE_MODE}" != ps_error ]] || fail_once ps
                    printf 'fixture-container\n'
                fi
                ;;
            stop)
                [[ "${PROBE_MODE}" != stop_error ]] || fail_once stop
                if [[ "${PROBE_MODE}" == rollback_stop_error && -e "${PROBE_ROOT}/up-attempted" ]]; then
                    exit 47
                fi
                printf 'stopped\n' >"${PROBE_ROOT}/state"
                ;;
            up)
                : >"${PROBE_ROOT}/up-attempted"
                printf 'running\n' >"${PROBE_ROOT}/state"
                case "${PROBE_MODE}" in
                    start_error | rollback_stop_error | rollback_move_error) fail_once up ;;
                    rollback_up_error) exit 48 ;;
                    signal)
                        if [[ ! -e "${PROBE_ROOT}/failed-signal" ]]; then
                            : >"${PROBE_ROOT}/failed-signal"
                            kill -TERM "${PPID}"
                        fi
                        ;;
                    *) ;;
                esac
                ;;
            *) exit 99 ;;
        esac
        ;;
    *) exit 99 ;;
esac
exit 0
EOF

cat >"${TEST_TMP}/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path="${*: -2:1}"
destination_path="${*: -1}"
case "${PROBE_MODE}:${source_path##*/}:${destination_path##*/}" in
    original_move_error:live:previous | candidate_move_error:candidate:live | rollback_move_error:previous:live)
        exit 49
        ;;
    *) exec /usr/bin/mv "$@" ;;
esac
EOF
chmod 0700 -- "${TEST_TMP}/bin/docker" "${TEST_TMP}/bin/mv"
export PATH="${TEST_TMP}/bin:${PATH}"
export VAULTWARDEN_RECOVERY_ENV_FILE=/nonexistent
export VAULTWARDEN_HEALTH_TIMEOUT_SECONDS=1
export PROBE_ROOT PROBE_MODE PREVIOUS_RUNNING
export VAULTWARDEN_BACKUP_ROOT VAULTWARDEN_STACK_DIR VAULTWARDEN_DATA_DIR VAULTWARDEN_STANDBY_MOUNT

prepare_case() {
    PROBE_ROOT="${TEST_TMP}/$1"
    PROBE_MODE="$2"
    PREVIOUS_RUNNING="${3:-true}"
    VAULTWARDEN_BACKUP_ROOT="${PROBE_ROOT}/backups"
    VAULTWARDEN_STACK_DIR="${PROBE_ROOT}/stack"
    # Deliberately omit stack/mnt: a custom data path must stand on its own.
    VAULTWARDEN_DATA_DIR="${PROBE_ROOT}/custom-data/live"
    VAULTWARDEN_STANDBY_MOUNT="${PROBE_ROOT}/standby"
    snapshot="${VAULTWARDEN_BACKUP_ROOT}/snapshots/20260905T000000Z"
    mkdir -p -- "${snapshot}/data" "${VAULTWARDEN_STACK_DIR}" \
        "${VAULTWARDEN_DATA_DIR}" "${VAULTWARDEN_STANDBY_MOUNT}/data"
    printf 'services: {}\n' >"${VAULTWARDEN_STACK_DIR}/compose.yaml"
    printf 'old\n' >"${VAULTWARDEN_DATA_DIR}/generation"
    printf 'old\n' >"${VAULTWARDEN_STANDBY_MOUNT}/data/generation"
    printf 'new\n' >"${snapshot}/data/generation"
    printf 'synthetic-key\n' >"${snapshot}/data/rsa_key.fixture"
    sqlite3 "${snapshot}/data/db.sqlite3" 'CREATE TABLE fixture(value TEXT);'
    printf '20260905T000000Z\n' >"${snapshot}/SNAPSHOT_ID"
    (
        cd -- "${snapshot}"
        sha256sum data/* >SHA256SUMS
    )
    ln -s snapshots/20260905T000000Z "${VAULTWARDEN_BACKUP_ROOT}/latest"
    : >"${PROBE_ROOT}/commands"
    printf 'running\n' >"${PROBE_ROOT}/state"
}

expect_restore_failure() {
    if "${REPO_ROOT}/src/scripts/vaultwarden_restore.sh" >"${PROBE_ROOT}/output" 2>&1; then
        printf 'restore accepted simulated failure: %s\n' "${PROBE_MODE}" >&2
        exit 1
    fi
}

for mode in receive_error receive_running receive_stopped; do
    prepare_case "${mode}" "${mode}"
    [[ "${mode}" != receive_stopped ]] || PREVIOUS_RUNNING=false
    tar -C "${snapshot}" -czf "${PROBE_ROOT}/snapshot.tar.gz" SNAPSHOT_ID SHA256SUMS data
    rm -rf -- "${VAULTWARDEN_BACKUP_ROOT}/snapshots" "${VAULTWARDEN_BACKUP_ROOT}/latest"
    status=0
    "${REPO_ROOT}/src/scripts/vaultwarden_backup_receive.sh" \
        <"${PROBE_ROOT}/snapshot.tar.gz" >"${PROBE_ROOT}/output" 2>&1 || status=$?
    if [[ "${mode}" == receive_error ]]; then
        ((status != 0))
    else
        ((status == 0))
    fi
    if [[ "${mode}" == receive_stopped ]]; then
        grep -qxF new "${VAULTWARDEN_STANDBY_MOUNT}/data/generation"
    else
        grep -qxF old "${VAULTWARDEN_STANDBY_MOUNT}/data/generation"
    fi
done

prepare_case verify success
"${REPO_ROOT}/src/scripts/vaultwarden_restore.sh" --verify >/dev/null
[[ ! -s "${PROBE_ROOT}/commands" ]]
grep -qxF old "${VAULTWARDEN_DATA_DIR}/generation"

prepare_case success success
"${REPO_ROOT}/src/scripts/vaultwarden_restore.sh" >/dev/null 2>&1
grep -qxF new "${VAULTWARDEN_DATA_DIR}/generation"
previous_files=("${VAULTWARDEN_DATA_DIR%/*}"/.live.restore.*/previous/generation)
grep -qxF old "${previous_files[0]}"

for mode in stop_error original_move_error candidate_move_error start_error ps_error inspect_error empty_container health_error health_timeout signal; do
    prepare_case "${mode}" "${mode}"
    expect_restore_failure
    grep -qxF old "${VAULTWARDEN_DATA_DIR}/generation"
    grep -qxF running "${PROBE_ROOT}/state"
    grep -Fq 'previous data and service state restored' "${PROBE_ROOT}/output"
done

prepare_case previously_stopped start_error false
expect_restore_failure
grep -qxF old "${VAULTWARDEN_DATA_DIR}/generation"
grep -qxF stopped "${PROBE_ROOT}/state"

prepare_case initially_missing start_error false
rm -rf -- "${VAULTWARDEN_DATA_DIR}"
expect_restore_failure
[[ ! -e "${VAULTWARDEN_DATA_DIR}" ]]
grep -qxF stopped "${PROBE_ROOT}/state"

for mode in rollback_stop_error rollback_up_error rollback_inspect_error rollback_move_error; do
    prepare_case "${mode}" "${mode}"
    expect_restore_failure
    grep -Fq 'rollback failed; recovery files retained' "${PROBE_ROOT}/output"
    if [[ "${mode}" == rollback_stop_error || "${mode}" == rollback_move_error ]]; then
        previous_files=("${VAULTWARDEN_DATA_DIR%/*}"/.live.restore.*/previous/generation)
        grep -qxF old "${previous_files[0]}"
    else
        grep -qxF old "${VAULTWARDEN_DATA_DIR}/generation"
    fi
done

printf 'Vaultwarden recovery tests passed\n'
