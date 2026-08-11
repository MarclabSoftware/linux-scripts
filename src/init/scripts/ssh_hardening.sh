#!/usr/bin/env bash

# Provisioning Module: OpenSSH Hardening
# Version: 4.1.0
# Updated: 2026-08-11
# Rotates the server host keys once, then keeps validating and updating a small
# sshd drop-in while preserving distribution settings and algorithm defaults.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154,SC2310

validateSSHHardeningConfiguration() {
    local port="${CONFIG_SSH_PORT:-}"
    local address_family="${CONFIG_SSH_ADDRESS_FAMILY:-}"
    local permit_root_login="${CONFIG_SSH_PERMIT_ROOT_LOGIN:-prohibit-password}"
    local penalty_exempt_list="${CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST:-}"
    local declaration directive keyword

    if [[ -n "${port}" ]] &&
        { [[ ! "${port}" =~ ^[0-9]+$ ]] ||
            ((10#${port} < 1 || 10#${port} > 65535)); }; then
        printf 'CONFIG_SSH_PORT must be empty or an integer from 1 to 65535\n' >&2
        return 1
    fi
    case "${address_family}" in
        "" | any | inet | inet6) ;;
        *)
            printf 'CONFIG_SSH_ADDRESS_FAMILY must be empty, any, inet or inet6\n' >&2
            return 1
            ;;
    esac
    case "${permit_root_login}" in
        no | prohibit-password | forced-commands-only) ;;
        *)
            printf 'CONFIG_SSH_PERMIT_ROOT_LOGIN must be no, prohibit-password or forced-commands-only\n' >&2
            return 1
            ;;
    esac
    case "${CONFIG_SSH_FORCE_HOST_KEY_ROTATION:-false}" in
        true | false) ;;
        *)
            printf 'CONFIG_SSH_FORCE_HOST_KEY_ROTATION must be true or false\n' >&2
            return 1
            ;;
    esac
    if [[ "${penalty_exempt_list}" == *[$'\r\n\t ']* ]]; then
        printf 'CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST must not contain whitespace\n' >&2
        return 1
    fi

    if declaration="$(declare -p CONFIG_SSH_EXTRA_DIRECTIVES 2>/dev/null)"; then
        [[ "${declaration}" == "declare -a "* ]] || {
            printf 'CONFIG_SSH_EXTRA_DIRECTIVES must be an indexed array\n' >&2
            return 1
        }
        for directive in "${CONFIG_SSH_EXTRA_DIRECTIVES[@]}"; do
            [[ -n "${directive}" && "${directive}" != *[$'\r\n']* ]] || {
                printf 'CONFIG_SSH_EXTRA_DIRECTIVES entries must be non-empty single lines\n' >&2
                return 1
            }
            keyword="${directive%%[[:space:]]*}"
            case "${keyword,,}" in
                hostkey | include | match)
                    printf 'CONFIG_SSH_EXTRA_DIRECTIVES cannot contain %s directives\n' \
                        "${keyword}" >&2
                    return 1
                    ;;
                *) ;;
            esac
        done
    fi
}

supportsMLDSAHostKey() {
    local supported_keys

    supported_keys="$(ssh -Q key 2>/dev/null)" || return
    grep -q '^ssh-mldsa44-ed25519' <<<"${supported_keys}"
}

renderSSHHardeningConfig() {
    local host_key_dir="${1:-/etc/ssh}"
    local include_mldsa="${2:-false}"
    local directive

    cat <<EOF
# Managed by linux-scripts. Local changes will be replaced.
# Distribution settings and OpenSSH algorithm defaults remain authoritative.

EOF

    [[ "${include_mldsa}" != true ]] ||
        printf 'HostKey %s/ssh_host_mldsa44_ed25519_key\n' "${host_key_dir}"
    printf '%s\n' \
        "HostKey ${host_key_dir}/ssh_host_ed25519_key" \
        "HostKey ${host_key_dir}/ssh_host_rsa_key"

    cat <<EOF

PermitRootLogin ${CONFIG_SSH_PERMIT_ROOT_LOGIN:-prohibit-password}
AuthenticationMethods publickey
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

LoginGraceTime 30
MaxAuthTries 3

X11Forwarding no
PermitUserEnvironment no
EOF

    [[ -z "${CONFIG_SSH_PORT:-}" ]] ||
        printf '\nPort %s\n' "${CONFIG_SSH_PORT}"
    [[ -z "${CONFIG_SSH_ADDRESS_FAMILY:-}" ]] ||
        printf 'AddressFamily %s\n' "${CONFIG_SSH_ADDRESS_FAMILY}"
    [[ -z "${CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST:-}" ]] ||
        printf 'PerSourcePenaltyExemptList %s\n' \
            "${CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST}"

    if declare -p CONFIG_SSH_EXTRA_DIRECTIVES >/dev/null 2>&1 &&
        ((${#CONFIG_SSH_EXTRA_DIRECTIVES[@]} > 0)); then
        printf '\n# Host-specific directives from the private init configuration.\n'
        for directive in "${CONFIG_SSH_EXTRA_DIRECTIVES[@]}"; do
            printf '%s\n' "${directive}"
        done
    fi
}

sshEffectiveValue() {
    local effective_config="$1"
    local keyword="$2"

    awk -v wanted="${keyword,,}" '
        tolower($1) == wanted {
            $1 = ""
            sub(/^[[:space:]]+/, "")
            print
            exit
        }
    ' <<<"${effective_config}"
}

assertSSHEffectiveValue() {
    local effective_config="$1"
    local keyword="$2"
    local expected="${3,,}"
    local accepted_alias="${4:-}"
    local actual

    actual="$(sshEffectiveValue "${effective_config}" "${keyword}")"
    actual="${actual,,}"
    if [[ "${actual}" != "${expected}" &&
        (-z "${accepted_alias}" || "${actual}" != "${accepted_alias,,}") ]]; then
        printf 'Effective sshd setting %s is %q, expected %q\n' \
            "${keyword}" "${actual}" "${expected}" >&2
        return 1
    fi
}

validateSSHEffectiveConfig() {
    local effective_config="$1"
    local host_key_dir="${2:-/etc/ssh}"
    local include_mldsa="${3:-false}"
    local root_alias=""
    local actual_host_keys expected_host_keys

    actual_host_keys="$(awk '
        tolower($1) == "hostkey" {
            key = tolower($2)
            if (!seen[key]++) {
                print key
            }
        }
    ' <<<"${effective_config}")"
    expected_host_keys="$(
        [[ "${include_mldsa}" != true ]] ||
            printf '%s\n' "${host_key_dir}/ssh_host_mldsa44_ed25519_key"
        printf '%s\n' \
            "${host_key_dir}/ssh_host_ed25519_key" \
            "${host_key_dir}/ssh_host_rsa_key"
    )"
    if [[ "${actual_host_keys}" != "${expected_host_keys,,}" ]]; then
        printf 'Effective sshd host keys do not match the managed policy\n' >&2
        return 1
    fi

    [[ "${CONFIG_SSH_PERMIT_ROOT_LOGIN:-prohibit-password}" != prohibit-password ]] ||
        root_alias="without-password"
    assertSSHEffectiveValue "${effective_config}" permitrootlogin \
        "${CONFIG_SSH_PERMIT_ROOT_LOGIN:-prohibit-password}" "${root_alias}" || return
    assertSSHEffectiveValue "${effective_config}" authenticationmethods publickey || return
    assertSSHEffectiveValue "${effective_config}" pubkeyauthentication yes || return
    assertSSHEffectiveValue "${effective_config}" authorizedkeysfile \
        .ssh/authorized_keys || return
    assertSSHEffectiveValue "${effective_config}" passwordauthentication no || return
    assertSSHEffectiveValue "${effective_config}" kbdinteractiveauthentication no || return
    assertSSHEffectiveValue "${effective_config}" permitemptypasswords no || return
    assertSSHEffectiveValue "${effective_config}" logingracetime 30 || return
    assertSSHEffectiveValue "${effective_config}" maxauthtries 3 || return
    assertSSHEffectiveValue "${effective_config}" x11forwarding no || return
    assertSSHEffectiveValue "${effective_config}" permituserenvironment no || return

    [[ -z "${CONFIG_SSH_PORT:-}" ]] ||
        assertSSHEffectiveValue "${effective_config}" port "${CONFIG_SSH_PORT}" || return
    [[ -z "${CONFIG_SSH_ADDRESS_FAMILY:-}" ]] ||
        assertSSHEffectiveValue "${effective_config}" addressfamily \
            "${CONFIG_SSH_ADDRESS_FAMILY}" || return
    [[ -z "${CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST:-}" ]] ||
        assertSSHEffectiveValue "${effective_config}" persourcepenaltyexemptlist \
            "${CONFIG_SSH_PER_SOURCE_PENALTY_EXEMPT_LIST}" || return
}

sshdIncludesDropInDirectory() {
    local main_config="$1"
    local drop_in_dir="$2"

    awk -v required="${drop_in_dir}/*.conf" '
        tolower($1) == "include" {
            for (field = 2; field <= NF; field++) {
                if ($field == required) {
                    found = 1
                }
            }
        }
        END { exit !found }
    ' "${main_config}"
}

activeSSHService() {
    local service

    for service in sshd.service ssh.service; do
        if systemctl is-active --quiet "${service}"; then
            printf '%s\n' "${service}"
            return 0
        fi
    done
    return 1
}

# Confirm that public-key-only authentication will not lock out the managed
# non-root account. OpenSSH StrictModes accepts paths owned by the user or root
# and rejects paths writable by group or others.
validateSSHUserAccess() {
    if (($# != 2)) || [[ "$1" != /* || -z "$2" ]]; then
        printf 'validateSSHUserAccess: expected absolute HOME and USER\n' >&2
        return 2
    fi

    local user_home="${1%/}"
    local user_name="$2"
    local ssh_dir="${user_home}/.ssh"
    local authorized_keys="${ssh_dir}/authorized_keys"
    local expected_uid actual_uid mode path

    expected_uid="$(id -u -- "${user_name}" 2>/dev/null)" || {
        printf 'Cannot resolve SSH account: %s\n' "${user_name}" >&2
        return 1
    }
    [[ -d "${user_home}" ]] || {
        printf 'SSH home directory is missing: %s\n' "${user_home}" >&2
        return 1
    }
    [[ -d "${ssh_dir}" && ! -L "${ssh_dir}" ]] || {
        printf 'SSH directory must be a real directory: %s\n' "${ssh_dir}" >&2
        return 1
    }
    [[ -f "${authorized_keys}" && ! -L "${authorized_keys}" ]] || {
        printf 'SSH authorized_keys must be a regular file: %s\n' \
            "${authorized_keys}" >&2
        return 1
    }

    for path in "${user_home}" "${ssh_dir}" "${authorized_keys}"; do
        actual_uid="$(stat -c '%u' -- "${path}")" || return
        mode="$(stat -c '%a' -- "${path}")" || return
        if [[ "${actual_uid}" != 0 && "${actual_uid}" != "${expected_uid}" ]]; then
            printf 'Unsafe SSH path owner: %s\n' "${path}" >&2
            return 1
        fi
        if (((8#${mode} & 8#022) != 0)); then
            printf 'SSH path must not be group/world writable: %s\n' \
                "${path}" >&2
            return 1
        fi
    done

    checkCommand ssh-keygen || return
    ssh-keygen -lf "${authorized_keys}" >/dev/null 2>&1 || {
        printf 'No valid public key found in %s\n' "${authorized_keys}" >&2
        return 1
    }
}

restoreSSHConfig() {
    local target_config="$1"
    local rollback_file="$2"
    local target_existed="$3"

    if [[ "${target_existed}" == true ]]; then
        mv -f -- "${rollback_file}" "${target_config}"
    else
        rm -f -- "${target_config}"
    fi
}

validateSSHHostKeyInventory() {
    local host_key_dir="$1"
    local key_name certificate
    local -a key_names=(rsa ecdsa ed25519 dsa xmss mldsa44_ed25519)

    for key_name in "${key_names[@]}"; do
        certificate="${host_key_dir}/ssh_host_${key_name}_key-cert.pub"
        [[ ! -e "${certificate}" && ! -L "${certificate}" ]] || {
            printf 'Host certificate requires manual rotation: %s\n' \
                "${certificate}" >&2
            return 1
        }
    done
}

existingSSHHostKeysIncludeMLDSA() {
    local host_key_dir="$1"
    local key_name private_key public_key

    for key_name in rsa ed25519; do
        private_key="${host_key_dir}/ssh_host_${key_name}_key"
        public_key="${private_key}.pub"
        [[ -f "${private_key}" && ! -L "${private_key}" &&
            -f "${public_key}" && ! -L "${public_key}" ]] || {
            printf 'Managed OpenSSH host-key pair is missing or unsafe: %s\n' \
                "${private_key}" >&2
            return 1
        }
        ssh-keygen -lf "${public_key}" >/dev/null || return
    done

    private_key="${host_key_dir}/ssh_host_mldsa44_ed25519_key"
    public_key="${private_key}.pub"
    if [[ ! -e "${private_key}" && ! -L "${private_key}" &&
        ! -e "${public_key}" && ! -L "${public_key}" ]]; then
        printf 'false\n'
        return 0
    fi
    [[ -f "${private_key}" && ! -L "${private_key}" &&
        -f "${public_key}" && ! -L "${public_key}" ]] || {
        printf 'Incomplete or unsafe OpenSSH MLDSA host-key pair\n' >&2
        return 1
    }
    ssh-keygen -lf "${public_key}" >/dev/null || return
    printf 'true\n'
}

writeSSHHostKeyRotationMarker() {
    local marker="$1"
    local marker_dir="${marker%/*}"
    local candidate

    [[ "${marker}" == /* && -n "${marker_dir}" &&
        ! -L "${marker}" && ! -d "${marker}" ]] || {
        printf 'Unsafe SSH host-key rotation marker path: %s\n' \
            "${marker}" >&2
        return 1
    }
    install -d -m 0700 -- "${marker_dir}" || return
    candidate="$(mktemp -- "${marker_dir}/.ssh-host-keys-rotated.XXXXXX")" ||
        return
    if ! printf 'OpenSSH host keys rotated by linux-scripts\n' >"${candidate}" ||
        ! chmod 0600 -- "${candidate}" ||
        ! mv -f -- "${candidate}" "${marker}"; then
        rm -f -- "${candidate}"
        return 1
    fi
}

generateSSHHostKeys() {
    local output_dir="$1"
    local include_mldsa="$2"
    local key_name
    local -a key_names=(rsa ed25519)

    ssh-keygen -q -t rsa -b 4096 -N '' -C '' \
        -f "${output_dir}/ssh_host_rsa_key" || return
    ssh-keygen -q -t ed25519 -N '' -C '' \
        -f "${output_dir}/ssh_host_ed25519_key" || return
    if [[ "${include_mldsa}" == true ]]; then
        ssh-keygen -q -t mldsa44-ed25519 -N '' -C '' \
            -f "${output_dir}/ssh_host_mldsa44_ed25519_key" || return
        key_names+=(mldsa44_ed25519)
    fi

    for key_name in "${key_names[@]}"; do
        ssh-keygen -lf "${output_dir}/ssh_host_${key_name}_key.pub" \
            >/dev/null || return
    done
}

backupSSHHostKeys() {
    local host_key_dir="$1"
    local backup_dir="$2"
    local key_name suffix source_file
    local -a key_names=(rsa ecdsa ed25519 dsa xmss mldsa44_ed25519)

    for key_name in "${key_names[@]}"; do
        for suffix in '' .pub; do
            source_file="${host_key_dir}/ssh_host_${key_name}_key${suffix}"
            [[ -e "${source_file}" || -L "${source_file}" ]] || continue
            [[ -f "${source_file}" && ! -L "${source_file}" ]] || {
                printf 'Invalid OpenSSH host-key file: %s\n' "${source_file}" >&2
                return 1
            }
            mv -- "${source_file}" "${backup_dir}/" || return
        done
    done
}

installSSHHostKeys() {
    local source_dir="$1"
    local host_key_dir="$2"
    local include_mldsa="$3"
    local key_name private_key public_key
    local -a key_names=(rsa ed25519)

    [[ "${include_mldsa}" != true ]] || key_names+=(mldsa44_ed25519)
    for key_name in "${key_names[@]}"; do
        private_key="ssh_host_${key_name}_key"
        public_key="${private_key}.pub"
        install -m 0600 -- "${source_dir}/${private_key}" \
            "${host_key_dir}/${private_key}" || return
        install -m 0644 -- "${source_dir}/${public_key}" \
            "${host_key_dir}/${public_key}" || return
        chown root:root "${host_key_dir}/${private_key}" \
            "${host_key_dir}/${public_key}" || return
    done
}

restoreSSHHostKeys() {
    local host_key_dir="$1"
    local backup_dir="$2"
    local key_name suffix target_file backup_file
    local -a key_names=(rsa ecdsa ed25519 dsa xmss mldsa44_ed25519)

    for key_name in "${key_names[@]}"; do
        for suffix in '' .pub; do
            target_file="${host_key_dir}/ssh_host_${key_name}_key${suffix}"
            rm -f -- "${target_file}" || return
            backup_file="${backup_dir}/${target_file##*/}"
            [[ -e "${backup_file}" ]] || continue
            mv -- "${backup_file}" "${target_file}" || return
        done
    done
}

cleanupSSHHostKeyTransaction() {
    local transaction_dir="$1"
    local host_key_dir="$2"

    [[ "${transaction_dir}" == "${host_key_dir}"/.linux-scripts-host-keys.* ]] || {
        printf 'Refusing unsafe host-key transaction cleanup: %s\n' \
            "${transaction_dir}" >&2
        return 1
    }
    rm -rf -- "${transaction_dir}"
}

rollbackSSHChanges() {
    local target_config="$1"
    local rollback_file="$2"
    local target_existed="$3"
    local host_key_dir="$4"
    local host_key_backup_dir="$5"
    local keys_rotated="$6"
    local failed=false

    restoreSSHConfig "${target_config}" "${rollback_file}" \
        "${target_existed}" || failed=true
    if [[ "${keys_rotated}" == true ]]; then
        restoreSSHHostKeys "${host_key_dir}" "${host_key_backup_dir}" ||
            failed=true
    fi
    [[ "${failed}" == false ]]
}

printSSHHostKeyFingerprints() {
    local host_key_dir="$1"
    local include_mldsa="$2"
    local key_name
    local -a key_names=(ed25519 rsa)

    [[ "${include_mldsa}" != true ]] ||
        key_names=(mldsa44_ed25519 "${key_names[@]}")
    printf 'New OpenSSH host-key fingerprints:\n'
    for key_name in "${key_names[@]}"; do
        ssh-keygen -lf "${host_key_dir}/ssh_host_${key_name}_key.pub" || return
    done
}

hardenSSH() {
    local main_config="${1:-/etc/ssh/sshd_config}"
    local drop_in_dir="${2:-/etc/ssh/sshd_config.d}"
    local host_key_dir="${3:-/etc/ssh}"
    local rotation_marker="${INIT_SSH_HOST_KEY_MARKER:-/var/lib/linux-scripts/ssh-host-keys.rotated}"
    local target_config="${drop_in_dir}/90-linux-scripts-sshd.conf"
    local candidate rollback_file effective_config active_service transaction_dir
    local new_key_dir old_key_dir
    local target_existed=false
    local include_mldsa=false
    local rotate_keys=false

    validateSSHHardeningConfiguration || return
    checkCommand sshd || return
    checkCommand ssh || return
    checkCommand ssh-keygen || return
    checkCommand systemctl || return
    validateSSHUserAccess "${HOME_USER_D}" "${CONFIG_USER}" || return
    active_service="$(activeSSHService)" || {
        printf 'OpenSSH must be active before hardening\n' >&2
        return 1
    }
    systemctl enable "${active_service}" || return
    [[ -r "${main_config}" ]] || {
        printf 'OpenSSH server configuration is not readable: %s\n' \
            "${main_config}" >&2
        return 1
    }
    sshdIncludesDropInDirectory "${main_config}" "${drop_in_dir}" || {
        printf '%s does not include %s/*.conf\n' \
            "${main_config}" "${drop_in_dir}" >&2
        return 1
    }
    [[ ! -L "${drop_in_dir}" && ! -L "${target_config}" ]] || {
        printf 'Symbolic-link OpenSSH drop-in path rejected: %s\n' \
            "${target_config}" >&2
        return 1
    }
    [[ "${host_key_dir}" == /* && -d "${host_key_dir}" &&
        ! -L "${host_key_dir}" ]] || {
        printf 'OpenSSH host-key directory must be an absolute real directory: %s\n' \
            "${host_key_dir}" >&2
        return 1
    }
    [[ "${rotation_marker}" == /* && ! -L "${rotation_marker}" &&
        ! -d "${rotation_marker}" ]] || {
        printf 'Unsafe SSH host-key rotation marker path: %s\n' \
            "${rotation_marker}" >&2
        return 1
    }
    if [[ -e "${rotation_marker}" ]]; then
        [[ -f "${rotation_marker}" ]] || {
            printf 'SSH host-key rotation marker is not a regular file: %s\n' \
                "${rotation_marker}" >&2
            return 1
        }
    else
        rotate_keys=true
    fi
    [[ "${CONFIG_SSH_FORCE_HOST_KEY_ROTATION:-false}" != true ]] ||
        rotate_keys=true
    validateSSHHostKeyInventory "${host_key_dir}" || return
    sshd -t || {
        printf 'Existing OpenSSH configuration is invalid; refusing to change it\n' >&2
        return 1
    }

    install -d -m 0755 -- "${drop_in_dir}" || return
    candidate="$(mktemp -- "${drop_in_dir}/.ssh-hardening-candidate.XXXXXX")" ||
        return
    if ! rollback_file="$(mktemp -- "${drop_in_dir}/.ssh-hardening-rollback.XXXXXX")"; then
        rm -f -- "${candidate}"
        return 1
    fi
    if [[ -e "${target_config}" ]]; then
        target_existed=true
        if ! cp -a -- "${target_config}" "${rollback_file}"; then
            rm -f -- "${candidate}" "${rollback_file}"
            return 1
        fi
    fi

    transaction_dir="$(mktemp -d -- \
        "${host_key_dir}/.linux-scripts-host-keys.XXXXXX")" || {
        rm -f -- "${candidate}" "${rollback_file}"
        return 1
    }
    new_key_dir="${transaction_dir}/new"
    old_key_dir="${transaction_dir}/old"
    if ! install -d -m 0700 -- "${new_key_dir}" "${old_key_dir}"; then
        cleanupSSHHostKeyTransaction "${transaction_dir}" "${host_key_dir}" || true
        rm -f -- "${candidate}" "${rollback_file}"
        return 1
    fi

    if [[ "${rotate_keys}" == true ]]; then
        supportsMLDSAHostKey && include_mldsa=true
        if ! generateSSHHostKeys "${new_key_dir}" "${include_mldsa}"; then
            cleanupSSHHostKeyTransaction "${transaction_dir}" "${host_key_dir}" || true
            rm -f -- "${candidate}" "${rollback_file}"
            return 1
        fi
        if ! backupSSHHostKeys "${host_key_dir}" "${old_key_dir}"; then
            if restoreSSHHostKeys "${host_key_dir}" "${old_key_dir}"; then
                cleanupSSHHostKeyTransaction \
                    "${transaction_dir}" "${host_key_dir}" || true
            else
                printf 'Host-key recovery data retained at %s\n' \
                    "${transaction_dir}" >&2
            fi
            rm -f -- "${candidate}" "${rollback_file}"
            return 1
        fi
        if ! installSSHHostKeys "${new_key_dir}" "${host_key_dir}" \
            "${include_mldsa}"; then
            if restoreSSHHostKeys "${host_key_dir}" "${old_key_dir}"; then
                cleanupSSHHostKeyTransaction \
                    "${transaction_dir}" "${host_key_dir}" || true
            else
                printf 'Host-key recovery data retained at %s\n' \
                    "${transaction_dir}" >&2
            fi
            rm -f -- "${candidate}" "${rollback_file}"
            return 1
        fi
    else
        include_mldsa="$(
            existingSSHHostKeysIncludeMLDSA "${host_key_dir}"
        )" || {
            cleanupSSHHostKeyTransaction \
                "${transaction_dir}" "${host_key_dir}" || true
            rm -f -- "${candidate}" "${rollback_file}"
            return 1
        }
    fi

    if ! renderSSHHardeningConfig "${host_key_dir}" "${include_mldsa}" \
        >"${candidate}" ||
        ! sshd -t -f "${candidate}"; then
        if [[ "${rotate_keys}" != true ]] ||
            restoreSSHHostKeys "${host_key_dir}" "${old_key_dir}"; then
            cleanupSSHHostKeyTransaction "${transaction_dir}" "${host_key_dir}" || true
        else
            printf 'Host-key recovery data retained at %s\n' "${transaction_dir}" >&2
        fi
        rm -f -- "${candidate}" "${rollback_file}"
        printf 'Generated OpenSSH host keys or hardening configuration are invalid\n' >&2
        return 1
    fi

    if ! installConfigFile "${target_config}" <"${candidate}" ||
        ! chown root:root "${target_config}" ||
        ! sshd -t ||
        ! effective_config="$(sshd -T)" ||
        ! validateSSHEffectiveConfig "${effective_config}" \
            "${host_key_dir}" "${include_mldsa}"; then
        if rollbackSSHChanges "${target_config}" "${rollback_file}" \
            "${target_existed}" "${host_key_dir}" "${old_key_dir}" \
            "${rotate_keys}"; then
            cleanupSSHHostKeyTransaction "${transaction_dir}" "${host_key_dir}" || true
            rm -f -- "${candidate}" "${rollback_file}"
            printf 'OpenSSH validation failed; previous configuration restored\n' >&2
        else
            printf 'OpenSSH validation and rollback failed; recovery data retained at %s\n' \
                "${transaction_dir}" >&2
        fi
        return 1
    fi

    if ! systemctl reload "${active_service}"; then
        if ! rollbackSSHChanges "${target_config}" "${rollback_file}" \
            "${target_existed}" "${host_key_dir}" "${old_key_dir}" \
            "${rotate_keys}"; then
            printf 'OpenSSH reload and rollback failed; recovery data retained at %s\n' \
                "${transaction_dir}" >&2
            return 1
        fi
        if ! sshd -t || ! systemctl reload "${active_service}"; then
            printf 'OpenSSH reload and rollback reload both failed\n' >&2
            return 1
        fi
        cleanupSSHHostKeyTransaction "${transaction_dir}" "${host_key_dir}" || true
        rm -f -- "${candidate}" "${rollback_file}"
        printf 'OpenSSH reload failed; previous configuration restored\n' >&2
        return 1
    fi

    if [[ "${rotate_keys}" == true ]]; then
        if ! writeSSHHostKeyRotationMarker "${rotation_marker}"; then
            if rollbackSSHChanges "${target_config}" "${rollback_file}" \
                "${target_existed}" "${host_key_dir}" "${old_key_dir}" true &&
                sshd -t && systemctl reload "${active_service}"; then
                cleanupSSHHostKeyTransaction \
                    "${transaction_dir}" "${host_key_dir}" || true
                rm -f -- "${candidate}" "${rollback_file}"
                printf 'Unable to record SSH host-key rotation; previous state restored\n' >&2
            else
                printf 'SSH rotation-marker failure and rollback failed; recovery data retained at %s\n' \
                    "${transaction_dir}" >&2
            fi
            return 1
        fi
        printSSHHostKeyFingerprints "${host_key_dir}" "${include_mldsa}" ||
            printf 'Warning: unable to print the new host-key fingerprints\n' >&2
    fi
    cleanupSSHHostKeyTransaction "${transaction_dir}" "${host_key_dir}" || return
    rm -f -- "${candidate}" "${rollback_file}"
    if [[ "${rotate_keys}" == true ]]; then
        printf 'OpenSSH host keys rotated once; hardening installed and validated\n'
    else
        printf 'OpenSSH host keys already rotated; hardening installed and validated\n'
    fi
}
