#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

ech_dir="${TEST_TMP}/ech"
fake_bin="${TEST_TMP}/bin"
mkdir -p -- "${ech_dir}" "${fake_bin}"
cp -- "${REPO_ROOT}/src/scripts/npmplus_ech_cloudflare.sh" "${ech_dir}/cron.sh"
chmod 0700 "${ech_dir}/cron.sh"

config="${ech_dir}/npmplus_ech_cloudflare.env"
cat >"${config}" <<'EOF'
CF_API_TOKEN=test-token
CF_ZONE=example.com
ECH_RECORD_NAME=ech.example.com
ECH_PUBLIC_NAME=public.example.com
ECH_IDENTIFIER=shared
ECH_SVC_PARAMS='alpn="h2" ipv4hint="192.0.2.10"'
EOF
chmod 0600 "${config}"

cat >"${fake_bin}/ech.sh" <<'EOF'
#!/bin/sh
set -eu

printf 'ECH\n' >>"${EVENT_LOG}"
current=${PWD}/${2%.ech}-current.ech
previous=${PWD}/${2%.ech}-previous.ech
[ ! -s "${current}" ] || mv -- "${current}" "${previous}"

if [ "${ECH_TEST_MODE:-success}" = fail ]; then
    exit 9
fi

printf 'new-key\n' >"${current}"
state=$(mktemp "${PWD}/config-ids.test.XXXXXX")
jq --argjson id 22 '.current += [$id]' "${PWD}/config-ids.json" >"${state}"
mv -- "${state}" "${PWD}/config-ids.json"
printf 'ZmFrZS1lY2g=\n'
EOF
chmod 0700 "${fake_bin}/ech.sh"

cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

headers=$(cat)
printf '%s\n' "${headers}" >>"${CURL_HEADERS_LOG}"
printf '%s\n' "$*" >>"${CURL_ARGS_LOG}"
if [[ -v CF_API_TOKEN || -v cf_api_token ]]; then
    printf 'Cloudflare token leaked through the child environment\n' >&2
    exit 98
fi

args=("$@")
url=${args[${#args[@]} - 1]}
method=GET
payload=
for ((index = 0; index < ${#args[@]}; index++)); do
    case ${args[index]} in
        --request)
            ((index += 1))
            method=${args[index]}
            ;;
        --data-binary)
            ((index += 1))
            payload=${args[index]}
            ;;
        *) ;;
    esac
done
printf '%s:%s\n' "${method}" "${url##*/}" >>"${EVENT_LOG}"

zone_id=11111111111111111111111111111111
record_id=22222222222222222222222222222222
mode=${CURL_TEST_MODE:-existing}

if [[ ${url} == */zones ]]; then
    printf '{"success":true,"result":[{"id":"%s","name":"example.com","status":"active"}]}\n' \
        "${zone_id}"
elif [[ ${url} == */dns_records && ${method} == GET ]]; then
    record_queries=$(<"${CURL_STATE}")
    ((record_queries += 1))
    printf '%s\n' "${record_queries}" >"${CURL_STATE}"
    if [[ ${mode} == create || ${mode} == ambiguous-create ]] && ((record_queries == 1)); then
        printf '{"success":true,"result":[]}\n'
    else
        printf '{"success":true,"result":[{"id":"%s","type":"HTTPS","name":"ech.example.com","data":{"priority":1,"target":".","value":"old"}}]}\n' \
            "${record_id}"
    fi
elif [[ ${url} == */dns_records && ${method} == POST ]]; then
    printf '%s\n' "${payload}" >"${CURL_CREATE_PAYLOAD_LOG}"
    if [[ ${mode} == ambiguous-create ]]; then
        exit 28
    fi
    printf '{"success":true,"result":{"id":"%s","type":"HTTPS","name":"ech.example.com","data":{"priority":1,"target":"."}}}\n' \
        "${record_id}"
elif [[ ${url} == */dns_records/${record_id} && ${method} == PATCH ]]; then
    printf '%s\n' "${payload}" >"${CURL_PAYLOAD_LOG}"
    case ${mode} in
        logical-error)
            printf '{"success":false,"errors":[{"code":1000,"message":"test failure"}]}\n'
            ;;
        transport-error)
            printf '{"success":false,"errors":[{"code":1001,"message":"transport failure"}]}\n'
            exit 22
            ;;
        ambiguous-patch | unverifiable-patch | unexpected-value)
            exit 28
            ;;
        *)
            jq -n --arg id "${record_id}" --argjson payload "${payload}" \
                '{success:true,result:{id:$id,type:"HTTPS",name:"ech.example.com",data:{priority:1,target:".",value:$payload.data.value}}}'
            ;;
    esac
elif [[ ${url} == */dns_records/${record_id} && ${method} == GET ]]; then
    [[ "${mode}" != unverifiable-patch ]] || exit 28
    value=old
    if [[ "${mode}" == ambiguous-patch ]]; then
        value="$(jq -r '.data.value' "${CURL_PAYLOAD_LOG}")"
    elif [[ "${mode}" == unexpected-value ]]; then
        value=concurrent-record-value
    fi
    jq -n --arg id "${record_id}" --arg value "${value}" \
        '{success:true,result:{id:$id,type:"HTTPS",name:"ech.example.com",data:{priority:1,target:".",value:$value}}}'
else
    printf 'Unexpected curl request: %s %s\n' "${method}" "${url}" >&2
    exit 99
fi
EOF
chmod 0700 "${fake_bin}/curl"

export CURL_ARGS_LOG="${TEST_TMP}/curl.args"
export CURL_CREATE_PAYLOAD_LOG="${TEST_TMP}/curl-create.payload"
export CURL_HEADERS_LOG="${TEST_TMP}/curl.headers"
export CURL_PAYLOAD_LOG="${TEST_TMP}/curl.payload"
export CURL_STATE="${TEST_TMP}/curl.state"
export EVENT_LOG="${TEST_TMP}/events"
export PATH="${fake_bin}:${PATH}"

reset_prepared_state() {
    rm -f -- "${ech_dir}/shared-current.ech" "${ech_dir}/shared-previous.ech"
    rm -f -- "${ech_dir}"/.npmplus_ech_cloudflare.*
    printf 'old-key\n' >"${ech_dir}/shared-current.ech"
    jq -n '{current: [], previous: [11]}' >"${ech_dir}/config-ids.json"
    : >"${CURL_ARGS_LOG}"
    : >"${CURL_CREATE_PAYLOAD_LOG}"
    : >"${CURL_HEADERS_LOG}"
    : >"${CURL_PAYLOAD_LOG}"
    : >"${EVENT_LOG}"
    printf '0\n' >"${CURL_STATE}"
}

assert_committed() {
    [[ ! -e "${ech_dir}/.npmplus_ech_cloudflare.pending" ]]
    [[ $(<"${ech_dir}/shared-current.ech") == new-key ]]
    [[ $(<"${ech_dir}/shared-previous.ech") == old-key ]]
    jq -e '.current == [22] and .previous == [11]' "${ech_dir}/config-ids.json" >/dev/null
}

assert_rolled_back() {
    [[ ! -e "${ech_dir}/.npmplus_ech_cloudflare.pending" ]]
    [[ $(<"${ech_dir}/shared-current.ech") == old-key ]]
    [[ ! -e ${ech_dir}/shared-previous.ech ]]
    jq -e '.current == [11] and .previous == []' "${ech_dir}/config-ids.json" >/dev/null
}

assert_token_private() {
    if grep -Fq -- 'test-token' "${CURL_ARGS_LOG}"; then
        printf 'Cloudflare token was exposed through curl arguments\n' >&2
        exit 1
    fi
    grep -Fq -- 'Authorization: Bearer test-token' "${CURL_HEADERS_LOG}"
}

"${ech_dir}/cron.sh" --check-config >/dev/null
chmod 0644 "${config}"
if "${ech_dir}/cron.sh" --check-config >/dev/null 2>&1; then
    printf 'world-readable configuration was accepted\n' >&2
    exit 1
fi
chmod 0600 "${config}"

reset_prepared_state
CURL_TEST_MODE=existing "${ech_dir}/cron.sh" >/dev/null
assert_committed
assert_token_private
grep -Fq -- 'name=example.com' "${CURL_ARGS_LOG}"
grep -Fq -- 'name.exact=ech.example.com' "${CURL_ARGS_LOG}"
grep -Fq -- '/zones/11111111111111111111111111111111/dns_records/22222222222222222222222222222222' \
    "${CURL_ARGS_LOG}"
[[ $(<"${EVENT_LOG}") == $'GET:zones\nGET:dns_records\nECH\nPATCH:22222222222222222222222222222222' ]]
jq -e '. == {data: {value: "alpn=\"h2\" ipv4hint=\"192.0.2.10\" ech=\"ZmFrZS1lY2g=\""}}' \
    "${CURL_PAYLOAD_LOG}" >/dev/null

reset_prepared_state
CURL_TEST_MODE=create "${ech_dir}/cron.sh" >/dev/null
assert_committed
assert_token_private
[[ $(<"${EVENT_LOG}") == $'GET:zones\nGET:dns_records\nPOST:dns_records\nECH\nPATCH:22222222222222222222222222222222' ]]
jq -e '. == {
    type: "HTTPS",
    name: "ech.example.com",
    ttl: 300,
    proxied: false,
    data: {priority: 1, target: ".", value: "alpn=\"h2\" ipv4hint=\"192.0.2.10\""}
}' "${CURL_CREATE_PAYLOAD_LOG}" >/dev/null

reset_prepared_state
CURL_TEST_MODE=ambiguous-create "${ech_dir}/cron.sh" >/dev/null
assert_committed
[[ $(<"${EVENT_LOG}") == $'GET:zones\nGET:dns_records\nPOST:dns_records\nGET:dns_records\nECH\nPATCH:22222222222222222222222222222222' ]]

reset_prepared_state
if CURL_TEST_MODE=logical-error "${ech_dir}/cron.sh" >/dev/null 2>&1; then
    printf 'Cloudflare logical failure was accepted\n' >&2
    exit 1
fi
assert_rolled_back

reset_prepared_state
if CURL_TEST_MODE=transport-error "${ech_dir}/cron.sh" >/dev/null 2>&1; then
    printf 'Cloudflare transport failure was accepted\n' >&2
    exit 1
fi
assert_rolled_back

reset_prepared_state
CURL_TEST_MODE=ambiguous-patch "${ech_dir}/cron.sh" >"${TEST_TMP}/ambiguous.output"
assert_committed
assert_token_private
grep -Fq 'Confirmed ECH publication with a record lookup' "${TEST_TMP}/ambiguous.output"
grep -Fxq 'GET:22222222222222222222222222222222' "${EVENT_LOG}"

for mode in unverifiable-patch unexpected-value; do
    reset_prepared_state
    if CURL_TEST_MODE="${mode}" "${ech_dir}/cron.sh" >"${TEST_TMP}/uncertain.output" 2>&1; then
        printf 'uncertain ECH publication reported success\n' >&2
        exit 1
    fi
    marker="${ech_dir}/.npmplus_ech_cloudflare.pending"
    [[ -f "${marker}" ]]
    old_key="$(jq -r .previous_key_file "${marker}")"
    new_key="$(jq -r .new_key_file "${marker}")"
    old_ids="$(jq -r .previous_ids_file "${marker}")"
    new_ids="$(jq -r .new_ids_file "${marker}")"
    grep -qxF old-key "${old_key}"
    grep -qxF new-key "${new_key}"
    jq -e '.current == [11] and .previous == []' "${old_ids}" >/dev/null
    jq -e '.current == [22] and .previous == [11]' "${new_ids}" >/dev/null
    [[ $(<"${ech_dir}/shared-current.ech") == new-key ]]
    [[ $(<"${ech_dir}/shared-previous.ech") == old-key ]]
    grep -Fq 'both key generations and IDs retained' "${TEST_TMP}/uncertain.output"
    before="$(cat "${EVENT_LOG}")"
    if "${ech_dir}/cron.sh" >"${TEST_TMP}/blocked.output" 2>&1; then
        printf 'unresolved ECH publication allowed another rotation\n' >&2
        exit 1
    fi
    after="$(cat "${EVENT_LOG}")"
    [[ "${before}" == "${after}" ]]
    grep -Fq 'earlier publication needs recovery' "${TEST_TMP}/blocked.output"
done

reset_prepared_state
cat >"${fake_bin}/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${*: -1}" != *.restore ]] || exit 23
exec /usr/bin/cp "$@"
EOF
chmod 0700 -- "${fake_bin}/cp"
if CURL_TEST_MODE=transport-error "${ech_dir}/cron.sh" >"${TEST_TMP}/rollback.output" 2>&1; then
    printf 'failed ECH rollback reported success\n' >&2
    exit 1
fi
grep -Fq 'ECH rollback failed; backups retained' "${TEST_TMP}/rollback.output"
marker="${ech_dir}/.npmplus_ech_cloudflare.pending"
old_key="$(jq -r .previous_key_file "${marker}")"
new_key="$(jq -r .new_key_file "${marker}")"
grep -qxF old-key "${old_key}"
grep -qxF new-key "${new_key}"
rm -- "${fake_bin}/cp"

reset_prepared_state
if ECH_TEST_MODE=fail "${ech_dir}/cron.sh" >/dev/null 2>&1; then
    printf 'ech.sh failure was accepted\n' >&2
    exit 1
fi
assert_rolled_back

printf 'npmplus_ech_cloudflare integration test passed\n'
