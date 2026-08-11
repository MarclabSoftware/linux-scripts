#!/usr/bin/env bash

# Provisioning Module: Docker Login
# Version: 3.0.0
# Updated: 2026-08-09
# Performs an interactive registry login as the configured normal user.
# Docker Hub's device-code flow can be completed from any browser, so the
# target host does not need a graphical session. Setting a username instead
# uses Docker's hidden password or personal-access-token prompt over the
# current terminal. Secrets are deliberately never accepted through init.env.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

validateDockerLoginConfiguration() {
    local registry="${CONFIG_DOCKER_REGISTRY:-}"
    local username="${CONFIG_DOCKER_USERNAME:-}"

    if [[ "${registry}" == -* ||
        "${registry}" == */* ||
        "${registry}" == *[[:space:]]* ]]; then
        printf 'CONFIG_DOCKER_REGISTRY must be empty or hostname[:port]\n' >&2
        return 1
    fi
    if [[ "${username}" == *[[:space:]]* ]]; then
        printf 'CONFIG_DOCKER_USERNAME must not contain whitespace\n' >&2
        return 1
    fi
}

dockerLogin() {
    local docker_path registry target username
    local -a login_command

    validateDockerLoginConfiguration || return
    checkCommand docker || return
    checkCommand sudo || return

    docker_path="$(command -v docker)"
    registry="${CONFIG_DOCKER_REGISTRY:-}"
    username="${CONFIG_DOCKER_USERNAME:-}"
    target="${registry:-Docker Hub}"
    login_command=("${docker_path}" login)
    [[ -z "${username}" ]] || login_command+=(--username "${username}")
    [[ -z "${registry}" ]] || login_command+=("${registry}")

    printf '\nDocker registry login: %s\n' "${target}"
    if [[ -z "${registry}" && -z "${username}" ]]; then
        printf 'Complete the displayed device code from any browser.\n'
    else
        printf 'Enter credentials in this terminal when prompted.\n'
    fi

    sudo -H -u "${CONFIG_USER}" -- "${login_command[@]}"
}
