#!/usr/bin/env bash

# Check the complete pre-update backup gate with fake package managers.
set -Eeuo pipefail
((EUID == 0)) || {
    printf 'system backup test skipped: requires root or a user namespace\n'
    exit 77
}
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
mkdir -- "${TEST_TMP}/bin" "${TEST_TMP}/input"
export UPDATE_TEST_ROOT="${TEST_TMP}"
for command_name in pacman apt-get paccache df; do
    cat >"${TEST_TMP}/bin/${command_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${0##*/}" "$*" >>"${UPDATE_TEST_ROOT}/commands"
EOF
done
cat >"${TEST_TMP}/bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${UPDATE_TEST_TAR_FAIL:-0}" == 1 ]]; then
    while (($#)); do
        if [[ "$1" == --file ]]; then printf 'partial archive\n' >"$2"; break; fi
        shift
    done
    exit 2
fi
exec /usr/bin/tar "$@"
EOF
chmod 0700 -- "${TEST_TMP}/bin/"*
export PATH="${TEST_TMP}/bin:${PATH}"
printf 'configuration data\n' >"${TEST_TMP}/input/config with spaces"

for platform in arch debian; do
    export SYSTEM_UPDATE_ENV_FILE="${TEST_TMP}/${platform}.env"
    cat >"${SYSTEM_UPDATE_ENV_FILE}" <<EOF
SYSTEM_UPDATE_BACKUP_ENABLED=1
SYSTEM_UPDATE_BACKUP_DIR='${TEST_TMP}/${platform}-backups'
SYSTEM_UPDATE_BACKUP_PATHS_FILE='${TEST_TMP}/selected.paths'
SYSTEM_UPDATE_LOCK_FILE='${TEST_TMP}/${platform}.lock'
EOF
    chmod 0600 -- "${SYSTEM_UPDATE_ENV_FILE}"
    for mode in missing failed_tar success; do
        rm -f -- "${TEST_TMP}/commands"
        printf '# selected paths\n\n%s\n' "${TEST_TMP}/input/config with spaces" >"${TEST_TMP}/selected.paths"
        export UPDATE_TEST_TAR_FAIL=0
        case "${mode}" in
            missing) printf '%s\n' "${TEST_TMP}/required-missing" >>"${TEST_TMP}/selected.paths" ;;
            failed_tar) UPDATE_TEST_TAR_FAIL=1 ;;
            success) printf '?%s\n' "${TEST_TMP}/optional-missing" >>"${TEST_TMP}/selected.paths" ;;
            *) exit 2 ;;
        esac
        if "${REPO_ROOT}/src/scripts/update_${platform}.sh" >"${TEST_TMP}/run.output" 2>&1; then
            [[ "${mode}" == success ]]
        else
            [[ "${mode}" != success ]]
        fi
        if [[ "${mode}" != success ]]; then
            if grep -Eq '^(pacman|apt-get) ' "${TEST_TMP}/commands"; then
                printf 'package update ran after a failed backup\n' >&2
                exit 1
            fi
            published="$(find "${TEST_TMP}" -path "*/${platform}-backups/*" -type f -print -quit)"
            [[ -z "${published}" ]]
        else
            grep -Eq '^(pacman|apt-get) ' "${TEST_TMP}/commands"
            archives=("${TEST_TMP}/${platform}-backups/"*.tar.gz)
            [[ "${#archives[@]}" == 1 && -f "${archives[0]}" ]]
            mode_bits="$(stat -c %a "${archives[0]}")"
            [[ "${mode_bits}" == 600 ]]
            content="$(/usr/bin/tar -xOf "${archives[0]}" "${TEST_TMP#/}/input/config with spaces")"
            [[ "${content}" == 'configuration data' ]]
            grep -Fq 'Optional backup path is absent' "${TEST_TMP}/run.output"
        fi
    done
done
printf 'System update backup tests passed\n'
