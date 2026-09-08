#!/usr/bin/env bash

# Create one shared mTLS client identity backed by a private RSA-4096 CA.
#
# Install the same encrypted PKCS#12 file on every trusted client. Every
# NPMplus instance only needs ca/ca.crt.pem to accept it; its normal ACME
# certificate remains the TLS server identity. Never copy the CA key to a server.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly CA_DAYS=36500
readonly CLIENT_DAYS=36500
readonly MIN_CA_VALIDITY_SECONDS=2838240000
readonly CA_PASSWORD_MIN_LENGTH=16
readonly CLIENT_PASSWORD_MIN_LENGTH=8
readonly RSA_BITS=4096
readonly PKCS12_ITERATIONS=200000
readonly CA_NAME='Private mTLS Root CA'
readonly CLIENT_NAME='shared-client'

stage=
CA_PASSWORD=
CLIENT_PASSWORD=

die() {
    printf 'mtls_certificates.sh: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local current_stage=${stage}

    CA_PASSWORD=
    CLIENT_PASSWORD=
    stage=
    [[ -z ${current_stage} || ! -d ${current_stage} ]] || rm -rf -- "${current_stage}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'EOF'
Usage:
  mtls_certificates.sh OUTPUT_DIR

The command creates one private CA and one shared client identity. Install the
same shared-client.p12 on every trusted device and upload only ca/ca.crt.pem to
NPMplus.

Passwords are requested from the terminal. The CA password must contain at
least 16 characters; the client import password at least 8. For non-interactive
use, set these variables to owner-only files containing one password:
  MTLS_CA_PASSWORD_FILE      CA private-key password
  MTLS_CLIENT_PASSWORD_FILE  client identity and PKCS#12 password

The CA key is encrypted with AES-256-CBC. Client PEM keys and PKCS#12 files use
the client password; PKCS#12 uses PBES2/PBKDF2, AES-256-CBC and a SHA-256 MAC.
Existing CAs and client identities are never overwritten.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_private_path() {
    local path=$1
    local description=$2
    local mode

    [[ -e ${path} ]] || return 0
    mode=$(stat -c '%a' -- "${path}") || die "cannot inspect ${description}: ${path}"
    (((8#${mode} & 8#077) == 0)) || die "${description} must not be accessible by group or others: ${path}"
}

read_password() {
    local description=$1
    local password_file=$2
    local confirm=$3
    local minimum_length=$4
    local password
    local confirmation

    if [[ -n ${password_file} ]]; then
        [[ -f ${password_file} && -r ${password_file} ]] ||
            die "${description} file is not readable: ${password_file}"
        require_private_path "${password_file}" "${description} file"
        password=$(<"${password_file}")
    else
        [[ -r /dev/tty && -w /dev/tty ]] ||
            die "${description} requires a terminal or a password file"
        read -r -s -p "${description}: " password </dev/tty || die "cannot read ${description}"
        printf '\n' >/dev/tty
        if [[ ${confirm} == true ]]; then
            read -r -s -p "Confirm ${description}: " confirmation </dev/tty ||
                die "cannot confirm ${description}"
            printf '\n' >/dev/tty
            [[ ${password} == "${confirmation}" ]] || die "${description} confirmation does not match"
        fi
    fi

    [[ ${password} != *$'\n'* && ${password} != *$'\r'* ]] ||
        die "${description} must contain exactly one line"
    ((${#password} >= minimum_length)) ||
        die "${description} must contain at least ${minimum_length} characters"
    REPLY=${password}
}

prepare_output_root() {
    local requested=$1
    local resolved

    mkdir -p -- "${requested}"
    resolved=$(cd -- "${requested}" && pwd -P)
    require_private_path "${resolved}" "output directory"
    printf '%s\n' "${resolved}"
}

check_ca() {
    local ca_dir=$1

    [[ -r ${ca_dir}/ca.crt.pem ]] || die "CA certificate is not readable: ${ca_dir}/ca.crt.pem"
    [[ -r ${ca_dir}/ca.key.pem ]] || die "CA private key is not readable: ${ca_dir}/ca.key.pem"
    require_private_path "${ca_dir}" "CA directory"
    require_private_path "${ca_dir}/ca.key.pem" "CA private key"
    openssl verify -x509_strict -check_ss_sig -CAfile "${ca_dir}/ca.crt.pem" \
        "${ca_dir}/ca.crt.pem" >/dev/null || die "CA certificate verification failed"
    openssl x509 -checkend "${MIN_CA_VALIDITY_SECONDS}" -noout \
        -in "${ca_dir}/ca.crt.pem" >/dev/null ||
        die "CA expires too soon; use a new OUTPUT_DIR to create the long-lived CA"
}

new_serial() {
    local random_hex

    random_hex=$(openssl rand -hex 19) || die "cannot generate a certificate serial number"
    REPLY=0x${random_hex}
}

print_result() {
    local kind=$1
    local directory=$2
    local certificate=$3

    printf '%s created: %s\n' "${kind}" "${directory}"
    openssl x509 -in "${certificate}" -noout -subject -serial -dates -fingerprint -sha256
}

init_ca() {
    local output_root=$1
    local ca_dir=${output_root}/ca
    local serial

    [[ ! -e ${ca_dir} ]] || die "CA already exists: ${ca_dir}"
    read_password 'CA private-key password' "${MTLS_CA_PASSWORD_FILE:-}" true \
        "${CA_PASSWORD_MIN_LENGTH}"
    CA_PASSWORD=${REPLY}
    new_serial
    serial=${REPLY}

    stage=$(mktemp -d "${output_root}/.ca.XXXXXX")
    chmod 0700 -- "${stage}"
    openssl genpkey -quiet \
        -algorithm RSA \
        -pkeyopt "rsa_keygen_bits:${RSA_BITS}" \
        -aes-256-cbc \
        -pass fd:3 \
        -out "${stage}/ca.key.pem" \
        3<<<"${CA_PASSWORD}"
    openssl req \
        -new \
        -x509 \
        -batch \
        -utf8 \
        -sha384 \
        -days "${CA_DAYS}" \
        -set_serial "${serial}" \
        -subj "/CN=${CA_NAME}" \
        -key "${stage}/ca.key.pem" \
        -passin fd:3 \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -addext 'subjectKeyIdentifier=hash' \
        -addext 'authorityKeyIdentifier=keyid:always' \
        -out "${stage}/ca.crt.pem" \
        3<<<"${CA_PASSWORD}"

    chmod 0600 -- "${stage}/ca.key.pem"
    chmod 0644 -- "${stage}/ca.crt.pem"
    openssl pkey -in "${stage}/ca.key.pem" -passin fd:3 -check -noout \
        3<<<"${CA_PASSWORD}" >/dev/null
    openssl verify -x509_strict -check_ss_sig -CAfile "${stage}/ca.crt.pem" \
        "${stage}/ca.crt.pem" >/dev/null

    mv -- "${stage}" "${ca_dir}"
    stage=
    print_result 'CA' "${ca_dir}" "${ca_dir}/ca.crt.pem"
}

issue_client() {
    local output_root=$1
    local name=${CLIENT_NAME}
    local ca_dir=${output_root}/ca
    local parent=${output_root}/clients
    local target=${parent}/${name}
    local ext_file
    local serial
    local certificate_modulus
    local key_modulus

    check_ca "${ca_dir}"
    [[ ! -e ${target} ]] || die "client identity already exists: ${target}"
    if [[ -z ${CA_PASSWORD} ]]; then
        read_password 'CA private-key password' "${MTLS_CA_PASSWORD_FILE:-}" false \
            "${CA_PASSWORD_MIN_LENGTH}"
        CA_PASSWORD=${REPLY}
    fi
    read_password 'client identity password' "${MTLS_CLIENT_PASSWORD_FILE:-}" true \
        "${CLIENT_PASSWORD_MIN_LENGTH}"
    CLIENT_PASSWORD=${REPLY}
    new_serial
    serial=${REPLY}

    mkdir -p -- "${parent}"
    chmod 0700 -- "${parent}"
    stage=$(mktemp -d "${parent}/.${name}.XXXXXX")
    chmod 0700 -- "${stage}"
    ext_file=${stage}/extensions.cnf
    cat >"${ext_file}" <<'EOF'
[leaf]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

    openssl genpkey -quiet \
        -algorithm RSA \
        -pkeyopt "rsa_keygen_bits:${RSA_BITS}" \
        -aes-256-cbc \
        -pass fd:3 \
        -out "${stage}/client.key.pem" \
        3<<<"${CLIENT_PASSWORD}"
    openssl req \
        -new \
        -batch \
        -utf8 \
        -sha384 \
        -subj "/CN=${name}" \
        -key "${stage}/client.key.pem" \
        -passin fd:3 \
        -out "${stage}/client.csr.pem" \
        3<<<"${CLIENT_PASSWORD}"
    openssl x509 \
        -req \
        -sha384 \
        -days "${CLIENT_DAYS}" \
        -set_serial "${serial}" \
        -in "${stage}/client.csr.pem" \
        -CA "${ca_dir}/ca.crt.pem" \
        -CAkey "${ca_dir}/ca.key.pem" \
        -passin fd:3 \
        -extfile "${ext_file}" \
        -extensions leaf \
        -out "${stage}/client.crt.pem" \
        3<<<"${CA_PASSWORD}"
    openssl pkcs12 \
        -export \
        -inkey "${stage}/client.key.pem" \
        -passin fd:3 \
        -in "${stage}/client.crt.pem" \
        -certfile "${ca_dir}/ca.crt.pem" \
        -name "${name}" \
        -caname "${CA_NAME}" \
        -keypbe AES-256-CBC \
        -certpbe AES-256-CBC \
        -macalg SHA256 \
        -iter "${PKCS12_ITERATIONS}" \
        -passout fd:4 \
        -out "${stage}/${name}.p12" \
        3<<<"${CLIENT_PASSWORD}" \
        4<<<"${CLIENT_PASSWORD}"

    openssl verify -x509_strict -auth_level 2 -purpose sslclient \
        -CAfile "${ca_dir}/ca.crt.pem" "${stage}/client.crt.pem" >/dev/null
    openssl pkcs12 -in "${stage}/${name}.p12" -noout -passin fd:3 \
        3<<<"${CLIENT_PASSWORD}"
    certificate_modulus=$(openssl x509 -in "${stage}/client.crt.pem" -noout -modulus) ||
        die "cannot inspect the generated client certificate"
    key_modulus=$(openssl rsa -in "${stage}/client.key.pem" -passin fd:3 -noout -modulus \
        3<<<"${CLIENT_PASSWORD}" 2>/dev/null) || die "cannot inspect the generated client key"
    [[ ${certificate_modulus} == "${key_modulus}" ]] ||
        die "generated client certificate and key do not match"

    rm -- "${stage}/client.csr.pem" "${ext_file}"
    chmod 0600 -- "${stage}/client.key.pem" "${stage}/${name}.p12"
    chmod 0644 -- "${stage}/client.crt.pem"
    mv -- "${stage}" "${target}"
    stage=
    print_result 'client identity' "${target}" "${target}/client.crt.pem"
}

for command_name in chmod mkdir mktemp mv openssl pwd rm stat; do
    require_command "${command_name}"
done
case $(openssl version) in
    'OpenSSL 3.'*) ;;
    *) die 'OpenSSL 3.x is required' ;;
esac

case ${1:-} in
    -h | --help)
        usage
        exit 0
        ;;
    '')
        usage >&2
        exit 2
        ;;
    *) ;;
esac

[[ $# -eq 1 ]] || die 'requires OUTPUT_DIR'
output_root=$(prepare_output_root "$1")
[[ -e ${output_root}/ca ]] || init_ca "${output_root}"
issue_client "${output_root}"
