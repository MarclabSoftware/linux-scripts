#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/src/scripts/mtls_certificates.sh"
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

ca_password_file=${TEST_TMP}/ca.password
client_password_file=${TEST_TMP}/client.password
short_client_password_file=${TEST_TMP}/short-client.password
pki_dir=${TEST_TMP}/pki
short_pki_dir=${TEST_TMP}/short-pki
p12_ca_cert=${TEST_TMP}/p12-ca.crt.pem
certificate_bag_count=
ca_trust=
nss_dir=
p12_ca_fingerprint=
printf '%s\n' 'test-ca-password-with-32-characters' >"${ca_password_file}"
printf '%s\n' 'easy1234' >"${client_password_file}"
printf '%s\n' 'short7' >"${short_client_password_file}"
chmod 0600 -- "${ca_password_file}" "${client_password_file}" \
    "${short_client_password_file}"

export MTLS_CA_PASSWORD_FILE=${ca_password_file}
export MTLS_CLIENT_PASSWORD_FILE=${client_password_file}

"${SCRIPT}" "${pki_dir}" >/dev/null

ca_fingerprint=$(openssl x509 -in "${pki_dir}/ca/ca.crt.pem" -noout -fingerprint -sha256)

ca_cert=${pki_dir}/ca/ca.crt.pem
ca_key=${pki_dir}/ca/ca.key.pem
client_cert=${pki_dir}/clients/shared-client/client.crt.pem
client_key=${pki_dir}/clients/shared-client/client.key.pem
client_p12=${pki_dir}/clients/shared-client/shared-client.p12
file_mode=

for generated_file in \
    "${ca_cert}" "${ca_key}" \
    "${client_cert}" "${client_key}" "${client_p12}"; do
    [[ -s ${generated_file} ]]
done

for private_file in "${ca_key}" "${client_key}" "${client_p12}"; do
    file_mode=$(stat -c '%a' -- "${private_file}")
    [[ ${file_mode} == 600 ]]
done

openssl verify -x509_strict -check_ss_sig -CAfile "${ca_cert}" "${ca_cert}" >/dev/null
openssl x509 -checkend 2838240000 -noout -in "${ca_cert}" >/dev/null
openssl verify -x509_strict -purpose sslclient -CAfile "${ca_cert}" "${client_cert}" >/dev/null
openssl x509 -checkend 2838240000 -noout -in "${client_cert}" >/dev/null
if openssl verify -purpose sslserver -CAfile "${ca_cert}" "${client_cert}" >/dev/null 2>&1; then
    printf 'client certificate was accepted for server authentication\n' >&2
    exit 1
fi

for certificate in "${ca_cert}" "${client_cert}"; do
    openssl x509 -in "${certificate}" -noout -text | grep -Fq 'Public-Key: (4096 bit)'
done

openssl pkcs12 \
    -in "${client_p12}" \
    -noout \
    -passin "file:${client_password_file}" >/dev/null
pkcs12_info=$(openssl pkcs12 \
    -in "${client_p12}" \
    -info \
    -noout \
    -passin "file:${client_password_file}" 2>&1)
[[ ${pkcs12_info} == *'AES-256-CBC, Iteration 200000'* ]]
[[ ${pkcs12_info} == *'MAC: sha256, Iteration 200000'* ]]
certificate_bag_count=$(grep -Fc 'Certificate bag' <<<"${pkcs12_info}")
[[ ${certificate_bag_count} == 2 ]]
openssl pkcs12 \
    -in "${client_p12}" \
    -cacerts \
    -nokeys \
    -out "${p12_ca_cert}" \
    -passin "file:${client_password_file}" >/dev/null
p12_ca_fingerprint=$(openssl x509 -in "${p12_ca_cert}" -noout -fingerprint -sha256)
[[ ${p12_ca_fingerprint} == "${ca_fingerprint}" ]]

if command -v certutil >/dev/null 2>&1 && command -v pk12util >/dev/null 2>&1; then
    nss_dir=${TEST_TMP}/nssdb
    mkdir -p -- "${nss_dir}"
    certutil -N --empty-password -d "sql:${nss_dir}"
    pk12util -d "sql:${nss_dir}" -i "${client_p12}" \
        -w "${client_password_file}" >/dev/null
    certutil -d "sql:${nss_dir}" -L -n shared-client >/dev/null
    certutil -d "sql:${nss_dir}" -L -n 'Private mTLS Root CA' >/dev/null
    certutil -d "sql:${nss_dir}" -K 2>/dev/null | grep -Fq shared-client
    ca_trust=$(certutil -d "sql:${nss_dir}" -L |
        awk '/^Private mTLS Root CA[[:space:]]/ { print $NF }')
    [[ ${ca_trust} == ',,' ]]

    certutil -d "sql:${nss_dir}" -M \
        -n 'Private mTLS Root CA' \
        -t 'T,,'
    ca_trust=$(certutil -d "sql:${nss_dir}" -L |
        awk '/^Private mTLS Root CA[[:space:]]/ { print $NF }')
    [[ ${ca_trust} == 'T,,' ]]
    certutil -d "sql:${nss_dir}" -V -n shared-client -u C
fi

if "${SCRIPT}" "${pki_dir}" >/dev/null 2>&1; then
    printf 'existing client identity was overwritten\n' >&2
    exit 1
fi
current_ca_fingerprint=$(openssl x509 -in "${pki_dir}/ca/ca.crt.pem" -noout -fingerprint -sha256)
[[ ${current_ca_fingerprint} == "${ca_fingerprint}" ]]

if MTLS_CLIENT_PASSWORD_FILE=${short_client_password_file} \
    "${SCRIPT}" "${short_pki_dir}" >/dev/null 2>&1; then
    printf 'short client password was accepted\n' >&2
    exit 1
fi
[[ ! -e ${short_pki_dir}/clients/shared-client ]]

printf 'mTLS certificate integration test passed\n'
