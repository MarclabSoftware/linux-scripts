#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

private_key="${TEST_TMP}/webos.key"
state_file="${TEST_TMP}/online"
options_file="${TEST_TMP}/power_state.conf"
: >"${private_key}"
printf '1\n' >"${state_file}"
: >"${options_file}"
chmod 0600 "${private_key}" "${state_file}" "${options_file}"

webos_env="${TEST_TMP}/webos.env"
cat >"${webos_env}" <<EOF
WEBOS_HOST=192.0.2.10
WEBOS_PRIVATE_KEY=${private_key}
WEBOS_TOKEN_CACHE=${TEST_TMP}/state/token
WEBOS_KNOWN_HOSTS=${TEST_TMP}/state/known_hosts
EOF
chmod 0600 "${webos_env}"
WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" --check-config |
    grep -Fx 'webos_devmode configuration is valid' >/dev/null

fake_bin="${TEST_TMP}/bin"
mkdir -p -- "${fake_bin}"

cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
case ${SSH_TEST_MODE:-online} in
    online) printf 'fresh-token\n' ;;
    offline) exit 255 ;;
    remote-error) exit 42 ;;
    *) exit 99 ;;
esac
EOF

cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >"${CURL_ARGS_LOG}"
token_argument=
while (($# > 0)); do
    if [[ $1 == --data-urlencode ]]; then
        shift
        token_argument=$1
        break
    fi
    shift
done
[[ ${token_argument} == sessionToken@* ]]
token_file=${token_argument#sessionToken@}
printf '%s' "$(<"${token_file}")" >"${CURL_TOKEN_LOG}"

[[ ${CURL_TEST_MODE:-success} != fail ]] || exit 22
printf '{"result":"success"}'
EOF
chmod 0700 "${fake_bin}/ssh" "${fake_bin}/curl"

export CURL_ARGS_LOG="${TEST_TMP}/curl.args"
export CURL_TOKEN_LOG="${TEST_TMP}/curl.token"
export PATH="${fake_bin}:${PATH}"

WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" >/dev/null
[[ $(<"${TEST_TMP}/state/token") == fresh-token ]]
[[ $(<"${CURL_TOKEN_LOG}") == fresh-token ]]
token_mode="$(stat -c '%a' "${TEST_TMP}/state/token")"
[[ ${token_mode} == 600 ]]
if grep -Fq -- 'fresh-token' "${CURL_ARGS_LOG}"; then
    printf 'webOS token leaked through curl arguments\n' >&2
    exit 1
fi

# A legacy cache with a trailing newline remains usable and is normalized.
printf 'cached-token\n' >"${TEST_TMP}/state/token"
SSH_TEST_MODE=offline WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" >/dev/null
[[ $(<"${CURL_TOKEN_LOG}") == cached-token ]]
token_size="$(stat -c '%s' "${TEST_TMP}/state/token")"
[[ ${token_size} == 12 ]]

rm -f -- "${TEST_TMP}/state/token"
set +e
SSH_TEST_MODE=offline WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" >/dev/null 2>&1
webos_status=$?
set -e
((webos_status == 75))

set +e
SSH_TEST_MODE=remote-error WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" >/dev/null 2>&1
webos_status=$?
set -e
((webos_status == 1))

printf 'cached-token' >"${TEST_TMP}/state/token"
set +e
CURL_TEST_MODE=fail SSH_TEST_MODE=offline WEBOS_ENV_FILE="${webos_env}" \
    "${REPO_ROOT}/src/scripts/webos_devmode.sh" >/dev/null 2>&1
webos_status=$?
set -e
((webos_status == 22))

grep -q '^SuccessExitStatus=75$' \
    "${REPO_ROOT}/systemd/webos_devmode@.service"

power_env="${TEST_TMP}/power.env"
cat >"${power_env}" <<EOF
POWER_STATE_SOURCE_FILE=${state_file}
POWER_STATE_MQTT_OPTIONS_FILE=${options_file}
EOF
chmod 0600 "${power_env}"
POWER_STATE_ENV_FILE="${power_env}" \
    "${REPO_ROOT}/src/scripts/power_state.sh" --check-config |
    grep -Fx 'power_state configuration is valid' >/dev/null

printf 'webOS and power configuration tests passed\n'
