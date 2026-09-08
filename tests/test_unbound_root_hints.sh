#!/usr/bin/env bash

# Exercise root-hints replacement with fake network and Unbound commands.
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
mkdir -- "${TEST_TMP}/bin"
cat >"${TEST_TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=""
while (($#)); do
    case "$1" in --output | -o) destination="$2"; shift ;; esac
    shift
done
case "${HINTS_TEST_MODE}" in
    download-failure) printf partial >"${destination}"; exit 18 ;;
    invalid) printf '<html>error</html>\n' >"${destination}" ;;
    unchanged) cp -- "${HINTS_TEST_DIR}/root.hints" "${destination}" ;;
    *) printf '. 3600 IN NS new.example.\nnew.example. 3600 IN A 192.0.2.53\n' >"${destination}" ;;
esac
EOF
cat >"${TEST_TMP}/bin/unbound-checkconf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check\n' >>"${HINTS_TEST_DIR}/checks"
count="$(wc -l <"${HINTS_TEST_DIR}/checks")"
[[ "${HINTS_TEST_MODE}" != check-failure || "${count}" != 1 ]]
EOF
cat >"${TEST_TMP}/bin/unbound-control" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "-c ${HINTS_TEST_DIR}/unbound.conf -s ${HINTS_TEST_DIR}/control.sock reload" ]]
printf 'reload\n' >>"${HINTS_TEST_DIR}/reloads"
count="$(wc -l <"${HINTS_TEST_DIR}/reloads")"
[[ "${HINTS_TEST_MODE}" != rollback-failure ]] || exit 1
[[ "${HINTS_TEST_MODE}" != reload-failure || "${count}" != 1 ]]
EOF
chmod 0700 -- "${TEST_TMP}/bin/"*
export PATH="${TEST_TMP}/bin:${PATH}" HINTS_TEST_MODE HINTS_TEST_DIR
for HINTS_TEST_MODE in success unchanged download-failure invalid check-failure reload-failure rollback-failure; do
    HINTS_TEST_DIR="${TEST_TMP}/${HINTS_TEST_MODE}"
    mkdir -- "${HINTS_TEST_DIR}"
    hints="${HINTS_TEST_DIR}/root.hints"
    printf '. 3600 IN NS old.example.\n' >"${hints}"
    chmod 0640 -- "${hints}"
    printf '# synthetic config\n' >"${HINTS_TEST_DIR}/unbound.conf"
    cp -- "${hints}" "${HINTS_TEST_DIR}/expected"
    original_inode="$(stat -c %i "${hints}")"
    if "${REPO_ROOT}/src/scripts/unbound_update_root_hints.sh" "${hints}" \
        "${HINTS_TEST_DIR}/unbound.conf" "${HINTS_TEST_DIR}/control.sock" >"${HINTS_TEST_DIR}/output" 2>&1; then
        [[ "${HINTS_TEST_MODE}" == success || "${HINTS_TEST_MODE}" == unchanged ]]
    else
        [[ "${HINTS_TEST_MODE}" != success && "${HINTS_TEST_MODE}" != unchanged ]]
    fi
    mode="$(stat -c %a "${hints}")"
    if [[ "${HINTS_TEST_MODE}" == success ]]; then
        grep -Fq 'NS new.example.' "${hints}"
        [[ "${mode}" == 644 ]]
    else
        cmp -- "${hints}" "${HINTS_TEST_DIR}/expected"
        restored_inode="$(stat -c %i "${hints}")"
        [[ "${mode}" == 640 && "${restored_inode}" == "${original_inode}" ]]
    fi
    if [[ "${HINTS_TEST_MODE}" == rollback-failure ]]; then
        backups=("${HINTS_TEST_DIR}/".root-hints.*/previous)
        candidates=("${HINTS_TEST_DIR}/".root-hints.*/candidate)
        cmp -- "${backups[0]}" "${HINTS_TEST_DIR}/expected"
        grep -Fq 'NS new.example.' "${candidates[0]}"
        grep -Fq 'recovery failed' "${HINTS_TEST_DIR}/output"
    else
        leftover="$(find "${HINTS_TEST_DIR}" -name '.root-hints.*' -print -quit)"
        [[ -z "${leftover}" ]]
    fi
    if [[ "${HINTS_TEST_MODE}" == unchanged ]]; then
        [[ ! -e "${HINTS_TEST_DIR}/checks" && ! -e "${HINTS_TEST_DIR}/reloads" ]]
    fi
done
printf 'Unbound root hints tests passed\n'
