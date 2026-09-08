#!/bin/sh
# Publish an NPMplus ECH configuration through Cloudflare DNS.
#
# Install this file as /data/tls/ech/cron.sh inside the NPMplus container
# (normally /opt/npmplus/tls/ech/cron.sh on the host). NPMplus runs it at
# startup and at the interval selected by ECH_ROTATION_INTERVAL.
#
# The script creates the Cloudflare HTTPS record when needed. It owns
# data.value (configured SvcParams plus ECH) but preserves every other field
# after creation. Ambiguous updates are checked against the remote record before
# rollback; an unresolved publication retains both generations for recovery.

set -eu
umask 077

script_dir=${0%/*}
[ "${script_dir}" != "$0" ] || script_dir=.
script_dir=$(CDPATH='' cd -- "${script_dir}" && pwd)
readonly script_dir

config=${NPMPLUS_ECH_ENV_FILE:-"${script_dir}/npmplus_ech_cloudflare.env"}
readonly config

die() {
    printf 'npmplus_ech_cloudflare: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command not found: $1"
}

usage() {
    cat <<'EOF'
Usage: npmplus_ech_cloudflare.sh [--check-config]

The default configuration file is npmplus_ech_cloudflare.env beside the
script. Set NPMPLUS_ECH_ENV_FILE to select another owner-only file.

Run --check-config before installing this script as the NPMplus ECH cron.sh.
EOF
}

validate_dns_name() {
    case $1 in
        "" | .* | *. | *..* | *[!A-Za-z0-9.-]*)
            die "$2 is not a valid DNS name"
            ;;
        *) ;;
    esac
    [ "${#1}" -le 253 ] || die "$2 is too long"
}

case ${1:-} in
    --check-config)
        [ "$#" -eq 1 ] || die "--check-config accepts no additional arguments"
        check_config=true
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    "")
        [ "$#" -eq 0 ] || die "unexpected arguments"
        check_config=false
        ;;
    *) die "unknown argument: $1" ;;
esac

require_command stat
[ -f "${config}" ] && [ -r "${config}" ] ||
    die "configuration file is not readable: ${config}"

config_mode=$(stat -c '%a' "${config}") ||
    die "cannot inspect configuration file permissions: ${config}"
case ${config_mode} in
    400 | 600) ;;
    *) die "configuration file must have mode 0400 or 0600: ${config}" ;;
esac

# Do not inherit or export credentials. The owner-controlled file is trusted
# shell syntax, just like the other private environment files in this project.
unset CF_API_TOKEN CF_ZONE ECH_RECORD_NAME ECH_PUBLIC_NAME ECH_IDENTIFIER ECH_SVC_PARAMS
# shellcheck disable=SC1090
. "${config}"

[ -n "${CF_API_TOKEN:-}" ] || die "CF_API_TOKEN is required"
[ -n "${CF_ZONE:-}" ] || die "CF_ZONE is required"
[ -n "${ECH_RECORD_NAME:-}" ] || die "ECH_RECORD_NAME is required"
[ -n "${ECH_PUBLIC_NAME:-}" ] || die "ECH_PUBLIC_NAME is required"
[ -n "${ECH_IDENTIFIER:-}" ] || die "ECH_IDENTIFIER is required"
ECH_SVC_PARAMS=${ECH_SVC_PARAMS:-'alpn="h3,h2,http/1.1"'}

unset cf_api_token
cf_api_token=${CF_API_TOKEN}
unset CF_API_TOKEN

[ "${cf_api_token}" != replace-with-token ] || die "CF_API_TOKEN is still a placeholder"
case ${cf_api_token} in
    *[[:cntrl:]]*) die "CF_API_TOKEN contains control characters" ;;
    *) ;;
esac
validate_dns_name "${CF_ZONE}" CF_ZONE
record_host=${ECH_RECORD_NAME}
case ${record_host} in
    \*.*) record_host=${record_host#*.} ;;
    *) ;;
esac
validate_dns_name "${record_host}" ECH_RECORD_NAME
case ${record_host} in
    "${CF_ZONE}" | *."${CF_ZONE}") ;;
    *) die "ECH_RECORD_NAME must belong to CF_ZONE" ;;
esac
validate_dns_name "${ECH_PUBLIC_NAME}" ECH_PUBLIC_NAME
case ${ECH_IDENTIFIER} in
    *[!A-Za-z0-9_-]*) die "ECH_IDENTIFIER contains unsafe characters" ;;
    *) ;;
esac
[ "${#ECH_IDENTIFIER}" -le 64 ] || die "ECH_IDENTIFIER is too long"
case " ${ECH_SVC_PARAMS} " in
    *[[:cntrl:]]*) die "ECH_SVC_PARAMS contains control characters" ;;
    *" ech="*) die "ECH_SVC_PARAMS must not define the managed ech parameter" ;;
    *) ;;
esac

if [ "${check_config}" = true ]; then
    unset cf_api_token
    printf 'npmplus_ech_cloudflare configuration is valid\n'
    exit 0
fi

for command_name in cp curl ech.sh flock jq mktemp mv rm; do
    require_command "${command_name}"
done

ech_dir=${script_dir}
config_ids=${ech_dir}/config-ids.json
current_key=${ech_dir}/${ECH_IDENTIFIER}-current.ech
previous_key=${ech_dir}/${ECH_IDENTIFIER}-previous.ech
api=https://api.cloudflare.com/client/v4
pending_marker=${ech_dir}/.npmplus_ech_cloudflare.pending

[ ! -e "${pending_marker}" ] ||
    die "an earlier publication needs recovery; inspect ${pending_marker} before another rotation"

[ -d "${ech_dir}" ] && [ -w "${ech_dir}" ] ||
    die "ECH directory is not writable: ${ech_dir}"
[ -f "${config_ids}" ] && [ -r "${config_ids}" ] && [ -w "${config_ids}" ] ||
    die "NPMplus ECH state is not writable: ${config_ids}"

# NPMplus prepares config-ids.json immediately before invoking cron.sh. An
# empty current array confirms this script is running through that wrapper.
jq -e '
    type == "object" and
    (.current | type == "array") and
    (.previous | type == "array") and
    (.current | length == 0)
' "${config_ids}" >/dev/null ||
    die "invalid ECH state; run this script through the NPMplus ECH scheduler"

exec 9>"${ech_dir}/.npmplus_ech_cloudflare.lock"
flock -n 9 || die "another ECH publication is already running"

[ ! -e "${previous_key}" ] ||
    die "unexpected previous key; NPMplus did not prepare the ECH directory"

had_current=false
if [ -e "${current_key}" ]; then
    [ -s "${current_key}" ] || die "current ECH key is empty: ${current_key}"
    had_current=true
fi

rollback_ids=$(mktemp "${ech_dir}/.npmplus_ech_cloudflare.ids.XXXXXX") ||
    die "cannot create the ECH rollback state"
rollback_key=$(mktemp "${ech_dir}/.npmplus_ech_cloudflare.key.XXXXXX") || {
    rm -f -- "${rollback_ids}"
    die "cannot create the ECH key backup"
}

# At script entry, NPMplus has moved the active config IDs to .previous. This
# file restores their pre-scheduler meaning if publication does not commit.
if ! jq -e '{current: .previous, previous: []}' "${config_ids}" >"${rollback_ids}"; then
    rm -f -- "${rollback_ids}" "${rollback_key}"
    die "cannot prepare the ECH state rollback"
fi
if [ "${had_current}" = true ]; then
    if ! cp -p -- "${current_key}" "${rollback_key}"; then
        rm -f -- "${rollback_ids}" "${rollback_key}"
        die "cannot back up the current ECH key"
    fi
else
    rm -f -- "${rollback_key}"
    rollback_key=
fi

rotation_started=false
committed=false
publication_uncertain=false
pending_key=
pending_ids=
previous_dns_value=${ECH_SVC_PARAMS}

rollback_rotation() {
    rollback_ok=true
    if [ "${had_current}" = true ]; then
        if ! cp -p -- "${rollback_key}" "${rollback_key}.restore" ||
            ! mv -f -- "${rollback_key}.restore" "${current_key}"; then
            rollback_ok=false
        fi
    else
        rm -f -- "${current_key}" || rollback_ok=false
    fi
    rm -f -- "${previous_key}" || rollback_ok=false
    if ! cp -p -- "${rollback_ids}" "${rollback_ids}.restore" ||
        ! mv -f -- "${rollback_ids}.restore" "${config_ids}"; then
        rollback_ok=false
    fi
    [ "${rollback_ok}" = true ]
}

finish() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    unset cf_api_token

    if [ "${committed}" != true ] && [ "${publication_uncertain}" = true ]; then
        printf 'npmplus_ech_cloudflare: publication uncertain; both key generations and IDs retained. Recovery state: %s\n' "${pending_marker}" >&2
        exit 1
    fi
    if [ "${rotation_started}" = true ] && [ "${committed}" != true ]; then
        # Errexit is deliberately disabled so every rollback step is attempted.
        # shellcheck disable=SC2310
        if ! rollback_rotation; then
            printf 'npmplus_ech_cloudflare: CRITICAL: ECH rollback failed; backups retained: %s %s\n' "${rollback_key}" "${rollback_ids}" >&2
            exit 1
        fi
    fi
    rm -f -- "${pending_marker}" || status=1
    [ -z "${rollback_ids}" ] || rm -f -- "${rollback_ids}" || status=1
    [ -z "${rollback_key}" ] || rm -f -- "${rollback_key}" || status=1
    [ -z "${pending_ids}" ] || rm -f -- "${pending_ids}" || status=1
    [ -z "${pending_key}" ] || rm -f -- "${pending_key}" || status=1
    exit "${status}"
}

api_errors() {
    printf '%s' "$1" |
        jq -r '.errors[]? | "Cloudflare error \(.code // "unknown"): \(.message // "unknown")"' \
            >&2 2>/dev/null || :
}

# The token is streamed to curl so it never appears in argv or the child
# environment. Only idempotent requests use automatic retries.
cloudflare_request() {
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "${cf_api_token}" |
        curl --silent --show-error --fail-with-body \
            --connect-timeout 5 \
            --max-time 20 \
            --header @- \
            "$@"
}

cloudflare_retry() {
    cloudflare_request \
        --retry 2 \
        --retry-all-errors \
        --retry-delay 1 \
        --retry-max-time 60 \
        "$@"
}

lookup_https_record() {
    set +e
    record_response=$(cloudflare_retry \
        --get \
        --data-urlencode 'type=HTTPS' \
        --data-urlencode "name.exact=${ECH_RECORD_NAME}" \
        "${api}/zones/${zone_id}/dns_records")
    record_status=$?
    set -e
    if [ "${record_status}" -ne 0 ]; then
        api_errors "${record_response}"
        die "cannot query the Cloudflare HTTPS record (curl exit ${record_status})"
    fi

    record_matches=$(printf '%s' "${record_response}" |
        jq -cer --arg name "${ECH_RECORD_NAME}" '
            select(.success == true and (.result | type) == "array") |
            [.result[] | select(
                .type == "HTTPS" and
                ((.name | ascii_downcase) == ($name | ascii_downcase))
            )]
        ') || {
        api_errors "${record_response}"
        die "Cloudflare returned an invalid DNS record list"
    }

    case $(printf '%s' "${record_matches}" | jq -r 'length') in
        0) record_id= ;;
        1)
            record_id=$(printf '%s' "${record_matches}" |
                jq -er '
                    .[0] |
                    select(.data.priority == 1 and .data.target == ".") |
                    .id |
                    select(type == "string" and test("^[0-9A-Fa-f]{32}$"))
                ') || die "the existing HTTPS record is not priority 1 with target ."
            previous_dns_value=$(printf '%s' "${record_matches}" |
                jq -er '.[0].data.value | select(type == "string")') ||
                die "the existing HTTPS record has no valid SvcParams value"
            ;;
        *) die "multiple HTTPS records exist for ECH_RECORD_NAME" ;;
    esac
}

# Require the exact record identity and service parameters before trusting its value.
record_value_from_response() {
    printf '%s' "$1" | jq -er --arg id "${record_id}" --arg name "${ECH_RECORD_NAME}" '
        select(.success == true) | .result |
        select(.id == $id and .type == "HTTPS" and
            ((.name | ascii_downcase) == ($name | ascii_downcase)) and
            .data.priority == 1 and .data.target == ".") |
        .data.value | select(type == "string")
    '
}

trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rotation_started=true

set +e
zone_response=$(cloudflare_retry \
    --get \
    --data-urlencode "name=${CF_ZONE}" \
    --data-urlencode 'status=active' \
    "${api}/zones")
zone_status=$?
set -e
if [ "${zone_status}" -ne 0 ]; then
    api_errors "${zone_response}"
    die "cannot query the Cloudflare zone (curl exit ${zone_status})"
fi
zone_id=$(printf '%s' "${zone_response}" |
    jq -er --arg zone "${CF_ZONE}" '
        select(.success == true and (.result | type) == "array") |
        [.result[] | select(
            (.name | ascii_downcase) == ($zone | ascii_downcase) and
            .status == "active"
        )] |
        select(length == 1) |
        .[0].id |
        select(type == "string" and test("^[0-9A-Fa-f]{32}$"))
    ') || {
    api_errors "${zone_response}"
    die "Cloudflare did not uniquely resolve the active zone"
}

lookup_https_record
if [ -z "${record_id}" ]; then
    create_payload=$(jq -n \
        --arg name "${ECH_RECORD_NAME}" \
        --arg value "${ECH_SVC_PARAMS}" \
        '{
            type: "HTTPS",
            name: $name,
            ttl: 300,
            proxied: false,
            data: {priority: 1, target: ".", value: $value}
        }') || die "cannot build the Cloudflare record creation request"

    # POST is deliberately not retried: an interrupted response does not prove
    # that Cloudflare rejected the creation. Confirm with a safe GET instead.
    set +e
    create_response=$(cloudflare_request \
        --request POST \
        --data-binary "${create_payload}" \
        "${api}/zones/${zone_id}/dns_records")
    create_status=$?
    set -e
    record_id=$(printf '%s' "${create_response}" |
        jq -er --arg name "${ECH_RECORD_NAME}" '
            select(.success == true) |
            .result |
            select(
                .type == "HTTPS" and
                ((.name | ascii_downcase) == ($name | ascii_downcase))
            ) |
            .id |
            select(type == "string" and test("^[0-9A-Fa-f]{32}$"))
        ' 2>/dev/null) || record_id=

    if [ -z "${record_id}" ]; then
        lookup_https_record
        if [ -z "${record_id}" ]; then
            api_errors "${create_response}"
            die "Cloudflare HTTPS record creation could not be confirmed (curl exit ${create_status})"
        fi
    else
        printf 'Created HTTPS record %s\n' "${ECH_RECORD_NAME}"
    fi
fi

cd -- "${ech_dir}"
if ! ech_config=$(ech.sh "${ECH_PUBLIC_NAME}" "${ECH_IDENTIFIER}"); then
    die "ech.sh failed to generate a new key"
fi
[ -n "${ech_config}" ] && [ -s "${current_key}" ] ||
    die "ech.sh did not produce a valid current key"
case ${ech_config} in
    *[!A-Za-z0-9+/=]*) die "ech.sh returned an invalid ECH configuration" ;;
    *) ;;
esac
if [ "${had_current}" = true ]; then
    [ -s "${previous_key}" ] || die "ech.sh did not preserve the previous key"
fi

dns_value="${ECH_SVC_PARAMS} ech=\"${ech_config}\""
payload=$(jq -n --arg value "${dns_value}" '{data: {value: $value}}') ||
    die "cannot build the Cloudflare request"
endpoint=${api}/zones/${zone_id}/dns_records/${record_id}

# Store both generations outside NPMplus's *.ech rotation pattern. A later
# scheduler invocation may rearrange runtime files before it sees our failure.
pending_key=$(mktemp "${ech_dir}/.npmplus_ech_cloudflare.next-key.XXXXXX") ||
    die "cannot create the new-key recovery copy"
pending_ids=$(mktemp "${ech_dir}/.npmplus_ech_cloudflare.next-ids.XXXXXX") ||
    die "cannot create the new-state recovery copy"
cp -p -- "${current_key}" "${pending_key}" || die "cannot preserve the new key"
cp -p -- "${config_ids}" "${pending_ids}" || die "cannot preserve the new config IDs"
jq -n --arg endpoint "${endpoint}" --arg old_value "${previous_dns_value}" --arg new_value "${dns_value}" \
    --arg old_key "${rollback_key}" --arg old_ids "${rollback_ids}" \
    --arg new_key "${pending_key}" --arg new_ids "${pending_ids}" \
    '{endpoint: $endpoint, previous_value: $old_value, new_value: $new_value,
      previous_key_file: $old_key, previous_ids_file: $old_ids,
      new_key_file: $new_key, new_ids_file: $new_ids}' >"${pending_marker}" ||
    die "cannot write ECH recovery state"

publication_uncertain=true
# This helper returns errors explicitly to the enclosing decision.
# shellcheck disable=SC2310
if response=$(cloudflare_retry \
    --request PATCH \
    --data-binary "${payload}" \
    "${endpoint}"); then
    curl_status=0
else
    curl_status=$?
fi

# This helper returns errors explicitly to the enclosing decision.
# shellcheck disable=SC2310
if [ "${curl_status}" -eq 0 ] && confirmed_value=$(record_value_from_response "${response}") &&
    [ "${confirmed_value}" = "${dns_value}" ]; then
    :
else
    api_errors "${response}"
    # A lost PATCH response does not prove rejection, even after retries.
    # This helper returns errors explicitly to the enclosing decision.
    # shellcheck disable=SC2310
    if verification=$(cloudflare_retry --request GET "${endpoint}") &&
        verified_value=$(record_value_from_response "${verification}"); then
        if [ "${verified_value}" = "${dns_value}" ]; then
            printf 'Confirmed ECH publication with a record lookup\n'
        elif [ "${verified_value}" = "${previous_dns_value}" ]; then
            publication_uncertain=false
            die "Cloudflare retained the previous value; rolling back local rotation"
        else
            die "Cloudflare returned an unexpected record value; publication remains uncertain"
        fi
    else
        die "cannot verify Cloudflare publication after an ambiguous PATCH response"
    fi
fi

committed=true
publication_uncertain=false
unset cf_api_token
printf 'ECH configuration published for %s\n' "${ECH_PUBLIC_NAME}"
