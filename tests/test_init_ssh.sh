#!/usr/bin/env bash

# Exercise SSH provisioning without reading or changing the host configuration.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/ssh_add_keys.sh
. "${REPO_ROOT}/src/init/scripts/ssh_add_keys.sh"
# shellcheck source=src/init/scripts/ssh_add_hosts.sh
. "${REPO_ROOT}/src/init/scripts/ssh_add_hosts.sh"
# shellcheck source=src/init/scripts/ssh_hardening.sh
. "${REPO_ROOT}/src/init/scripts/ssh_hardening.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

# Use a fresh public key so the test does not depend on repository fixtures.
ssh-keygen -q -t ed25519 -N '' -f "${TEST_TMP}/test-key"
CONFIG_USER="$(id -un)"
CONFIG_SSH_KEY_USER="$(<"${TEST_TMP}/test-key.pub")"
CONFIG_SSH_KEY_ROOT=""
user_home="${TEST_TMP}/user-home"
root_home="${TEST_TMP}/root-home"

addSSHKeys "${user_home}" "${root_home}" >/dev/null
addSSHKeys "${user_home}" "${root_home}" >/dev/null
grep -qxF -- "${CONFIG_SSH_KEY_USER}" "${user_home}/.ssh/authorized_keys"
key_count="$(grep -cxF -- "${CONFIG_SSH_KEY_USER}" \
    "${user_home}/.ssh/authorized_keys")"
ssh_dir_mode="$(stat -c '%a' "${user_home}/.ssh")"
authorized_keys_mode="$(stat -c '%a' "${user_home}/.ssh/authorized_keys")"
[[ "${key_count}" == 1 ]]
[[ "${ssh_dir_mode}" == 700 ]]
[[ "${authorized_keys_mode}" == 600 ]]
chmod 0700 -- "${user_home}"
validateSSHUserAccess "${user_home}" "${CONFIG_USER}"
chmod 0770 -- "${user_home}/.ssh"
expect_failure validateSSHUserAccess "${user_home}" "${CONFIG_USER}"
chmod 0700 -- "${user_home}/.ssh"
printf 'invalid public key\n' >"${user_home}/.ssh/authorized_keys"
expect_failure validateSSHUserAccess "${user_home}" "${CONFIG_USER}"
printf '%s\n' "${CONFIG_SSH_KEY_USER}" \
    >"${user_home}/.ssh/authorized_keys"
CONFIG_SSH_KEY_USER="invalid public key"
expect_failure validateSSHKeyConfiguration
CONFIG_SSH_KEY_USER="$(<"${TEST_TMP}/test-key.pub")"

read -r key_type key_data _ <"${TEST_TMP}/test-key.pub"
known_hosts_source="${TEST_TMP}/verified-known-hosts"
known_hosts_target="${TEST_TMP}/etc/ssh/ssh_known_hosts"
printf 'new.example %s %s\n' "${key_type}" "${key_data}" \
    >"${known_hosts_source}"
printf '# Verified test inventory\n\n' >>"${known_hosts_source}"
mkdir -p -- "${known_hosts_target%/*}"
printf 'old.example %s %s\n' "${key_type}" "${key_data}" \
    >"${known_hosts_target}"
CONFIG_SSH_KNOWN_HOSTS_FILE="${known_hosts_source}"
addSSHHosts "${known_hosts_target}" >/dev/null
addSSHHosts "${known_hosts_target}" >/dev/null
known_host_count="$(grep -cF -- "${key_data}" "${known_hosts_target}")"
known_hosts_comment_count="$(grep -cxF '# Verified test inventory' \
    "${known_hosts_target}")"
known_hosts_mode="$(stat -c '%a' "${known_hosts_target}")"
[[ "${known_host_count}" == 2 ]]
[[ "${known_hosts_comment_count}" == 1 ]]
[[ "${known_hosts_mode}" == 644 ]]

CONFIG_SSH_PORT="2222"
CONFIG_SSH_ADDRESS_FAMILY="inet"
CONFIG_SSH_PERMIT_ROOT_LOGIN="prohibit-password"
CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST="192.0.2.10/32"
CONFIG_SSH_FORCE_HOST_KEY_ROTATION=false
CONFIG_SSH_EXTRA_DIRECTIVES=("AllowUsers ${CONFIG_USER}")
validateSSHHardeningConfiguration
CONFIG_SSH_EXTRA_DIRECTIVES=("Match User root")
expect_failure validateSSHHardeningConfiguration
CONFIG_SSH_EXTRA_DIRECTIVES=("AllowUsers ${CONFIG_USER}")

SSHD_TEST_FAIL_EFFECTIVE=false
SSH_SERVICE_ACTIVE=true
SSH_KEYGEN_GENERATION=0
SYSTEMCTL_LOG="${TEST_TMP}/systemctl.log"
HOME_USER_D="${user_home}"

ssh-keygen() {
    local output_file=""
    local key_type=""
    local key_bits="default"

    if [[ "$1" == -lf ]]; then
        [[ -f "$2" ]] || return 1
        printf '4096 SHA256:test %s (TEST)\n' "$2"
        return 0
    fi
    while (($# > 0)); do
        case "$1" in
            -q)
                shift
                ;;
            -t)
                key_type="$2"
                shift 2
                ;;
            -b)
                key_bits="$2"
                shift 2
                ;;
            -N | -C)
                shift 2
                ;;
            -f)
                output_file="$2"
                shift 2
                ;;
            *)
                return 2
                ;;
        esac
    done
    [[ -n "${output_file}" && -n "${key_type}" ]] || return 2
    ((SSH_KEYGEN_GENERATION += 1))
    printf 'generation=%s type=%s bits=%s\n' \
        "${SSH_KEYGEN_GENERATION}" "${key_type}" "${key_bits}" \
        >"${output_file}"
    printf 'public generation=%s type=%s\n' \
        "${SSH_KEYGEN_GENERATION}" "${key_type}" >"${output_file}.pub"
}

ssh() {
    [[ "$1" == -Q && "$2" == key ]] || return 2
    printf '%s\n' ssh-ed25519 ssh-mldsa44-ed25519@openssh.com
}

sshd() {
    local password_authentication=no

    [[ "${SSHD_TEST_FAIL_EFFECTIVE}" != true ]] ||
        password_authentication=yes
    case "$1" in
        -t)
            return 0
            ;;
        -T)
            printf '%s\n' \
                "HostKey ${HOST_KEY_DIR}/ssh_host_mldsa44_ed25519_key" \
                "HostKey ${HOST_KEY_DIR}/ssh_host_ed25519_key" \
                "HostKey ${HOST_KEY_DIR}/ssh_host_rsa_key" \
                'PermitRootLogin without-password' \
                'AuthenticationMethods publickey' \
                'PubkeyAuthentication yes' \
                'AuthorizedKeysFile .ssh/authorized_keys' \
                "PasswordAuthentication ${password_authentication}" \
                'KbdInteractiveAuthentication no' \
                'PermitEmptyPasswords no' \
                'LoginGraceTime 30' \
                'MaxAuthTries 3' \
                'X11Forwarding no' \
                'PermitUserEnvironment no' \
                'Port 2222' \
                'AddressFamily inet' \
                'PerSourcePenaltyExemptList 192.0.2.10/32'
            ;;
        *)
            return 2
            ;;
    esac
}

systemctl() {
    case "$1" in
        is-active)
            [[ "${SSH_SERVICE_ACTIVE}" == true &&
                "${3:-}" == sshd.service ]]
            ;;
        enable)
            printf 'enable %s\n' "$2" >>"${SYSTEMCTL_LOG}"
            ;;
        reload)
            printf '%s\n' "$2" >>"${SYSTEMCTL_LOG}"
            ;;
        *)
            return 2
            ;;
    esac
}

# hardenSSH normally runs as root through init.sh; ownership is not material in
# this unprivileged temporary-directory test.
chown() {
    return 0
}

main_config="${TEST_TMP}/sshd_config"
drop_in_dir="${TEST_TMP}/sshd_config.d"
HOST_KEY_DIR="${TEST_TMP}/etc/ssh"
INIT_SSH_HOST_KEY_MARKER="${TEST_TMP}/state/ssh-host-keys.rotated"
target_config="${drop_in_dir}/90-linux-scripts-sshd.conf"
mkdir -p -- "${HOST_KEY_DIR}"
printf 'legacy RSA key\n' >"${HOST_KEY_DIR}/ssh_host_rsa_key"
printf 'legacy RSA public key\n' >"${HOST_KEY_DIR}/ssh_host_rsa_key.pub"
printf 'legacy Ed25519 key\n' >"${HOST_KEY_DIR}/ssh_host_ed25519_key"
printf 'legacy Ed25519 public key\n' \
    >"${HOST_KEY_DIR}/ssh_host_ed25519_key.pub"
printf 'legacy ECDSA key\n' >"${HOST_KEY_DIR}/ssh_host_ecdsa_key"
printf 'legacy ECDSA public key\n' >"${HOST_KEY_DIR}/ssh_host_ecdsa_key.pub"
printf 'Include %s/*.conf\n' "${drop_in_dir}" >"${main_config}"

SSH_SERVICE_ACTIVE=false
expect_failure hardenSSH "${main_config}" "${drop_in_dir}" "${HOST_KEY_DIR}"
SSH_SERVICE_ACTIVE=true
hardenSSH "${main_config}" "${drop_in_dir}" "${HOST_KEY_DIR}" >/dev/null
grep -Fx "HostKey ${HOST_KEY_DIR}/ssh_host_mldsa44_ed25519_key" \
    "${target_config}" >/dev/null
grep -Fx 'AuthenticationMethods publickey' "${target_config}" >/dev/null
grep -Fx "AllowUsers ${CONFIG_USER}" "${target_config}" >/dev/null
target_mode="$(stat -c '%a' "${target_config}")"
rsa_mode="$(stat -c '%a' "${HOST_KEY_DIR}/ssh_host_rsa_key")"
reload_count="$(grep -cxF sshd.service "${SYSTEMCTL_LOG}")"
[[ "${target_mode}" == 644 ]]
[[ "${rsa_mode}" == 600 ]]
grep -F 'bits=4096' "${HOST_KEY_DIR}/ssh_host_rsa_key" >/dev/null
[[ ! -e "${HOST_KEY_DIR}/ssh_host_ecdsa_key" ]]
[[ "${reload_count}" == 1 ]]
[[ -f "${INIT_SSH_HOST_KEY_MARKER}" ]]

# A normal rerun reapplies policy without rotating the host identity.
first_rsa_key="$(<"${HOST_KEY_DIR}/ssh_host_rsa_key")"
hardenSSH "${main_config}" "${drop_in_dir}" "${HOST_KEY_DIR}" >/dev/null
[[ "$(<"${HOST_KEY_DIR}/ssh_host_rsa_key")" == "${first_rsa_key}" ]]
reload_count="$(grep -cxF sshd.service "${SYSTEMCTL_LOG}")"
[[ "${reload_count}" == 2 ]]

# The explicit force flag remains available for an intentional later rotation.
CONFIG_SSH_FORCE_HOST_KEY_ROTATION=true
hardenSSH "${main_config}" "${drop_in_dir}" "${HOST_KEY_DIR}" >/dev/null
[[ "$(<"${HOST_KEY_DIR}/ssh_host_rsa_key")" != "${first_rsa_key}" ]]
reload_count="$(grep -cxF sshd.service "${SYSTEMCTL_LOG}")"
[[ "${reload_count}" == 3 ]]

# A failed effective-policy check restores both the drop-in and host keys.
previous_config="$(<"${target_config}")"
previous_rsa_key="$(<"${HOST_KEY_DIR}/ssh_host_rsa_key")"
CONFIG_SSH_EXTRA_DIRECTIVES=("AllowGroups users")
SSHD_TEST_FAIL_EFFECTIVE=true
expect_failure hardenSSH "${main_config}" "${drop_in_dir}" "${HOST_KEY_DIR}"
[[ "$(<"${target_config}")" == "${previous_config}" ]]
[[ "$(<"${HOST_KEY_DIR}/ssh_host_rsa_key")" == "${previous_rsa_key}" ]]
reload_count="$(grep -cxF sshd.service "${SYSTEMCTL_LOG}")"
[[ "${reload_count}" == 3 ]]

printf 'init SSH tests passed\n'
