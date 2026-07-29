#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

letsencrypt_dir="${TEST_TMP}/letsencrypt"
archive_dir="${letsencrypt_dir}/archive/example.invalid"
live_dir="${letsencrypt_dir}/live/example.invalid"
mkdir -p -- "${archive_dir}" "${live_dir}" "${letsencrypt_dir}/csr" "${letsencrypt_dir}/keys"

for version in 1 2 3; do
    for component in cert chain fullchain privkey; do
        : >"${archive_dir}/${component}${version}.pem"
    done
done
ln -s -- "../../archive/example.invalid/privkey3.pem" "${live_dir}/privkey.pem"

env_file="${TEST_TMP}/npm_cleaner.env"
cat >"${env_file}" <<EOF
NPM_CLEANER_LETSENCRYPT_DIR=${letsencrypt_dir}
NPM_CLEANER_KEEP_OLD_VERSIONS=1
NPM_CLEANER_KEEP_CSR_DAYS=180
NPM_CLEANER_KEEP_KEYS_DAYS=180
NPM_CLEANER_DRY_RUN=1
EOF
chmod 0600 "${env_file}"

NPM_CLEANER_ENV_FILE="${env_file}" "${REPO_ROOT}/src/scripts/npm_cleaner.sh"
[[ -e "${archive_dir}/privkey1.pem" ]]

sed -i 's/NPM_CLEANER_DRY_RUN=1/NPM_CLEANER_DRY_RUN=0/' "${env_file}"
NPM_CLEANER_ENV_FILE="${env_file}" "${REPO_ROOT}/src/scripts/npm_cleaner.sh"
[[ ! -e "${archive_dir}/privkey1.pem" ]]
[[ -e "${archive_dir}/privkey2.pem" && -e "${archive_dir}/privkey3.pem" ]]
