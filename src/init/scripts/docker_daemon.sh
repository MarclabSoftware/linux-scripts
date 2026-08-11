#!/usr/bin/env bash

# Provisioning module: Docker daemon policy.
#
# Renders the small host-specific daemon.json used by the managed hosts,
# validates it with dockerd itself and restores the previous file if an active
# daemon cannot restart with the new policy.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154,SC2310

validateDockerDaemonConfiguration() {
    local prefix prefix_length

    case "${CONFIG_DOCKER_EXPERIMENTAL:-}" in
        true | false) ;;
        *)
            printf 'CONFIG_DOCKER_EXPERIMENTAL must be true or false\n' >&2
            return 1
            ;;
    esac
    case "${CONFIG_DOCKER_FIREWALL_BACKEND:-}" in
        "" | iptables | nftables) ;;
        *)
            printf 'CONFIG_DOCKER_FIREWALL_BACKEND must be empty, iptables or nftables\n' >&2
            return 1
            ;;
    esac
    if [[ "${CONFIG_DOCKER_FIREWALL_BACKEND:-}" == nftables &&
        "${CONFIG_DOCKER_EXPERIMENTAL}" != true ]]; then
        printf 'The Docker nftables backend currently requires experimental mode\n' >&2
        return 1
    fi
    [[ "${CONFIG_DOCKER_LOG_DRIVER:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        printf 'CONFIG_DOCKER_LOG_DRIVER must be a Docker logging-driver name\n' >&2
        return 1
    }
    case "${CONFIG_DOCKER_IPV6:-}" in
        true | false) ;;
        *)
            printf 'CONFIG_DOCKER_IPV6 must be true or false\n' >&2
            return 1
            ;;
    esac

    prefix="${CONFIG_DOCKER_FIXED_CIDR_V6:-}"
    if [[ "${CONFIG_DOCKER_IPV6}" != true && -n "${prefix}" ]]; then
        printf 'CONFIG_DOCKER_FIXED_CIDR_V6 requires CONFIG_DOCKER_IPV6=true\n' >&2
        return 1
    fi
    [[ -z "${prefix}" ]] || [[ "${prefix}" =~ ^[0-9A-Fa-f:]+/([0-9]{1,3})$ ]] || {
        printf 'CONFIG_DOCKER_FIXED_CIDR_V6 must be empty or an IPv6 CIDR\n' >&2
        return 1
    }
    if [[ -n "${prefix}" ]]; then
        prefix_length="${BASH_REMATCH[1]}"
        ((10#${prefix_length} <= 128)) || {
            printf 'CONFIG_DOCKER_FIXED_CIDR_V6 prefix length must not exceed 128\n' >&2
            return 1
        }
    fi
}

renderDockerDaemonConfiguration() {
    local separator=""

    printf '{\n'
    printf '    "experimental": %s' "${CONFIG_DOCKER_EXPERIMENTAL}"
    separator=$',\n'
    if [[ -n "${CONFIG_DOCKER_FIREWALL_BACKEND}" ]]; then
        printf '%s    "firewall-backend": "%s"' \
            "${separator}" "${CONFIG_DOCKER_FIREWALL_BACKEND}"
    fi
    printf '%s    "log-driver": "%s"' \
        "${separator}" "${CONFIG_DOCKER_LOG_DRIVER}"
    if [[ "${CONFIG_DOCKER_IPV6}" == true ]]; then
        printf '%s    "ipv6": true' "${separator}"
        [[ -z "${CONFIG_DOCKER_FIXED_CIDR_V6}" ]] ||
            printf '%s    "fixed-cidr-v6": "%s"' \
                "${separator}" "${CONFIG_DOCKER_FIXED_CIDR_V6}"
    fi
    printf '\n}\n'
}

restoreDockerDaemonConfiguration() {
    local target="$1"
    local backup="$2"
    local target_existed="$3"

    if [[ "${target_existed}" == true ]]; then
        mv -f -- "${backup}" "${target}"
    else
        rm -f -- "${target}"
    fi
}

configureDockerDaemon() {
    local target="${1:-/etc/docker/daemon.json}"
    local target_dir="${target%/*}"
    local transaction_dir candidate backup
    local target_existed=false
    local daemon_active=false

    validateDockerDaemonConfiguration || return
    checkCommand dockerd || return
    checkCommand systemctl || return
    [[ "${target}" == /* && -n "${target_dir}" ]] || {
        printf 'Docker daemon configuration path must be absolute\n' >&2
        return 1
    }
    [[ ! -L "${target_dir}" && ! -L "${target}" && ! -d "${target}" ]] || {
        printf 'Unsafe Docker daemon configuration path rejected: %s\n' \
            "${target}" >&2
        return 1
    }

    install -d -m 0755 -- "${target_dir}" || return
    transaction_dir="$(mktemp -d -- \
        "${target_dir}/.linux-scripts-daemon.XXXXXX")" || return
    candidate="${transaction_dir}/daemon.json"
    backup="${transaction_dir}/previous-daemon.json"

    if ! renderDockerDaemonConfiguration >"${candidate}" ||
        ! dockerd --validate --config-file "${candidate}"; then
        rm -rf -- "${transaction_dir}"
        printf 'Docker daemon configuration is invalid\n' >&2
        return 1
    fi
    if [[ -e "${target}" ]]; then
        target_existed=true
        cp -a -- "${target}" "${backup}" || {
            rm -rf -- "${transaction_dir}"
            return 1
        }
    fi
    systemctl is-active --quiet docker.service && daemon_active=true

    if ! installConfigFile "${target}" <"${candidate}" ||
        ! chown root:root "${target}" ||
        ! { [[ "${daemon_active}" != true ]] ||
            systemctl restart docker.service; } ||
        ! { [[ "${daemon_active}" != true ]] ||
            systemctl is-active --quiet docker.service; }; then
        if restoreDockerDaemonConfiguration \
            "${target}" "${backup}" "${target_existed}" &&
            { [[ "${daemon_active}" != true ]] ||
                systemctl restart docker.service; }; then
            rm -rf -- "${transaction_dir}"
            printf 'Docker restart failed; previous configuration restored\n' >&2
        else
            printf 'Docker rollback failed; recovery data retained at %s\n' \
                "${transaction_dir}" >&2
        fi
        return 1
    fi

    rm -rf -- "${transaction_dir}"
    printf 'Docker daemon configuration installed and validated\n'
}
