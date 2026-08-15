#!/usr/bin/env bash

# LG webOS Developer Mode Session Renewer
# Version: 2.1.0
# Updated: 2026-08-15
#
# Reads the current Developer Mode token over SSH and submits it to LG's renewal
# endpoint. A cached token is used only when the TV is temporarily unavailable.
# Secrets remain in a private SSH key and an ignored sidecar environment file.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/webos_devmode.env"
readonly EX_TEMPFAIL=75

die() {
    printf 'webos_devmode: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command not found: $1"
}

load_environment() {
    local env_file="${WEBOS_ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local env_mode

    [[ -e "${env_file}" ]] || return 0
    [[ -f "${env_file}" && -r "${env_file}" ]] ||
        die "environment file is not readable: ${env_file}"
    env_mode="$(stat -c '%a' "${env_file}")"
    (((8#${env_mode} & 8#022) == 0)) ||
        die "environment file must not be group/world writable: ${env_file}"

    set -a
    # The environment file is trusted administrator-controlled shell syntax.
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
}

load_environment

readonly HOST="${WEBOS_HOST:-}"
readonly PORT="${WEBOS_PORT:-9922}"
readonly USERNAME="${WEBOS_USERNAME:-prisoner}"
readonly PRIVATE_KEY="${WEBOS_PRIVATE_KEY:-}"
readonly CONNECT_TIMEOUT="${WEBOS_CONNECT_TIMEOUT:-3}"
readonly REQUEST_TIMEOUT="${WEBOS_REQUEST_TIMEOUT:-10}"
readonly TOKEN_CACHE="${WEBOS_TOKEN_CACHE:-${XDG_STATE_HOME:-${HOME}/.local/state}/webos_devmode/session_token}"
readonly KNOWN_HOSTS="${WEBOS_KNOWN_HOSTS:-${XDG_STATE_HOME:-${HOME}/.local/state}/webos_devmode/known_hosts}"
readonly API_URL="${WEBOS_API_URL:-https://developer.lge.com/secure/ResetDevModeSession.dev}"

[[ -n "${HOST}" && "${HOST}" != *[[:space:]]* ]] ||
    die "WEBOS_HOST is required and must contain no whitespace"
[[ -n "${USERNAME}" && "${USERNAME}" != *[[:space:]]* ]] ||
    die "WEBOS_USERNAME must contain no whitespace"
[[ "${PORT}" =~ ^[0-9]+$ && "${PORT}" -ge 1 && "${PORT}" -le 65535 ]] ||
    die "WEBOS_PORT must be between 1 and 65535"
[[ "${CONNECT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
    die "WEBOS_CONNECT_TIMEOUT must be a positive integer"
[[ "${REQUEST_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
    die "WEBOS_REQUEST_TIMEOUT must be a positive integer"
for configured_path in "${PRIVATE_KEY}" "${TOKEN_CACHE}" "${KNOWN_HOSTS}"; do
    [[ "${configured_path}" == /* ]] || die "configured file paths must be absolute"
done
[[ "${API_URL}" == https://* ]] || die "WEBOS_API_URL must use HTTPS"

case "${1:-}" in
    --check-config)
        [[ -r "${PRIVATE_KEY}" ]] || die "private key is not readable: ${PRIVATE_KEY}"
        printf 'webos_devmode configuration is valid\n'
        exit 0
        ;;
    --help | -h)
        printf 'Usage: webos_devmode.sh [--check-config]\n'
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1" ;;
esac

require_command curl
require_command ssh
[[ -r "${PRIVATE_KEY}" ]] || die "private key is not readable: ${PRIVATE_KEY}"

mkdir -p -- "${TOKEN_CACHE%/*}" "${KNOWN_HOSTS%/*}"
chmod 0700 -- "${TOKEN_CACHE%/*}" "${KNOWN_HOSTS%/*}"

ssh_status=0
session_token="$(
    ssh \
        -i "${PRIVATE_KEY}" \
        -p "${PORT}" \
        -o BatchMode=yes \
        -o ConnectTimeout="${CONNECT_TIMEOUT}" \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o IdentitiesOnly=yes \
        -o PasswordAuthentication=no \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${KNOWN_HOSTS}" \
        "${USERNAME}@${HOST}" \
        cat /var/luna/preferences/devmode_enabled
)" || ssh_status=$?

if ((ssh_status == 0)) && [[ -n ${session_token} ]]; then
    :
elif [[ -r "${TOKEN_CACHE}" ]]; then
    session_token="$(<"${TOKEN_CACHE}")"
elif ((ssh_status == 255)); then
    printf '%s\n' \
        'webos_devmode: TV unavailable and no cached token; retry deferred' >&2
    exit "${EX_TEMPFAIL}"
elif ((ssh_status == 0)); then
    die "the TV returned an empty session token"
else
    die "remote token command failed (SSH exit ${ssh_status})"
fi

[[ -n "${session_token}" ]] || die "the session token is empty"

# Normalize both fresh and legacy cached tokens, then let curl read the value
# from the owner-only file so it never appears in process arguments.
token_tmp="$(mktemp -- "${TOKEN_CACHE}.tmp.XXXXXX")"
printf '%s' "${session_token}" >"${token_tmp}"
mv -f -- "${token_tmp}" "${TOKEN_CACHE}"
chmod 0600 -- "${TOKEN_CACHE}"
unset session_token token_tmp

curl \
    --fail \
    --get \
    --max-time "${REQUEST_TIMEOUT}" \
    --show-error \
    --silent \
    --data-urlencode "sessionToken@${TOKEN_CACHE}" \
    "${API_URL}"
printf '\n'
