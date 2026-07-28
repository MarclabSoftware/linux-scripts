#!/usr/bin/env bash
set -euo pipefail
umask 077

# Minimal integration test: generate an ephemeral certificate, run the real
# one-shot conversion path, and validate the resulting unencrypted PFX.
script_dir=$(dirname -- "${BASH_SOURCE[0]}")
repo_root=$(cd -- "${script_dir}/.." && pwd)
monitor=${repo_root}/src/scripts/cert_monitor.sh

temp_dir=$(mktemp -d)
trap 'rm -rf -- "${temp_dir}"' EXIT

source_dir=${temp_dir}/source
output_file=${temp_dir}/output/certificate.pfx
mkdir -p -- "${source_dir}" "${temp_dir}/output"

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -nodes \
    -days 1 \
    -subj /CN=example.invalid \
    -keyout "${source_dir}/privkey.pem" \
    -out "${source_dir}/fullchain.pem" \
    >/dev/null 2>&1

"${monitor}" \
    --once \
    --source-dir "${source_dir}" \
    --output "${output_file}" \
    --settle-seconds 0

[[ -s ${output_file} ]]
output_permissions=$(stat -c '%a' "${output_file}")
[[ ${output_permissions} == 600 ]]
openssl pkcs12 -in "${output_file}" -noout -passin pass: >/dev/null

printf 'cert_monitor integration test passed\n'
