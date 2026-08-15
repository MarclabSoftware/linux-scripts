#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

tool_dir="${TEST_TMP}/tool"
fake_bin="${TEST_TMP}/bin"
mkdir -p -- "${tool_dir}/.git" "${fake_bin}"

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_ARGS_LOG}"
exit "${GIT_TEST_STATUS:-0}"
EOF

cat >"${tool_dir}/ssh-audit.py" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${AUDIT_ARGS_LOG}"
printf 'audit output\n'
if [[ ${AUDIT_USAGE_ERROR:-0} == 1 ]]; then
    printf 'usage: ssh-audit.py [options] host\nssh-audit.py: error: invalid arguments\n' >&2
fi
exit "${AUDIT_TEST_STATUS:-0}"
EOF
chmod 0700 "${fake_bin}/git" "${tool_dir}/ssh-audit.py"

export AUDIT_ARGS_LOG="${TEST_TMP}/audit.args"
export GIT_ARGS_LOG="${TEST_TMP}/git.args"
export PATH="${fake_bin}:${PATH}"
export SSH_AUDIT_TOOL_DIR="${tool_dir}"
export SSH_CONNECTION='198.51.100.10 54321 192.0.2.10 2222'

AUDIT_TEST_STATUS=2 "${REPO_ROOT}/src/scripts/ssh_audit.sh" >/dev/null 2>&1
[[ $(<"${AUDIT_ARGS_LOG}") == $'-4\n-p\n2222\nlocalhost' ]]
grep -Fx 'pull --ff-only --depth 1 --no-tags' "${GIT_ARGS_LOG}" >/dev/null

AUDIT_TEST_STATUS=3 "${REPO_ROOT}/src/scripts/ssh_audit.sh" >/dev/null 2>&1

set +e
AUDIT_TEST_STATUS=1 "${REPO_ROOT}/src/scripts/ssh_audit.sh" >/dev/null 2>&1
audit_status=$?
set -e
((audit_status == 1))

set +e
AUDIT_TEST_STATUS=255 "${REPO_ROOT}/src/scripts/ssh_audit.sh" >/dev/null 2>&1
audit_status=$?
set -e
((audit_status == 255))

set +e
AUDIT_TEST_STATUS=2 AUDIT_USAGE_ERROR=1 \
    "${REPO_ROOT}/src/scripts/ssh_audit.sh" --invalid >/dev/null 2>&1
audit_status=$?
set -e
((audit_status == 2))

set +e
GIT_TEST_STATUS=9 "${REPO_ROOT}/src/scripts/ssh_audit.sh" >/dev/null 2>&1
audit_status=$?
set -e
((audit_status == 1))

printf 'ssh_audit tests passed\n'
