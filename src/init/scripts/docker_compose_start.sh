#!/usr/bin/env bash

# Provisioning module: Docker Compose startup.
#
# Validates one Compose file and starts its project in detached mode during
# phase two. Compose resolves relative paths from the first specified file, so
# no working-directory mutation or project-directory override is required.
#
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

validateDockerComposeConfiguration() {
    local compose_file="${CONFIG_DOCKER_COMPOSE_FILE_PATH:-}"

    [[ "${compose_file}" == /* &&
        "${compose_file}" != *[$'\r\n']* ]] || {
        printf 'CONFIG_DOCKER_COMPOSE_FILE_PATH must be a single-line absolute path\n' >&2
        return 1
    }
}

startDockerCompose() {
    local compose_file
    local -a compose_command

    validateDockerComposeConfiguration || return
    checkCommand docker || return
    compose_file="${CONFIG_DOCKER_COMPOSE_FILE_PATH}"
    [[ -f "${compose_file}" && -r "${compose_file}" ]] || {
        printf 'Compose file is not a readable regular file: %s\n' \
            "${compose_file}" >&2
        return 1
    }

    docker compose version >/dev/null || {
        printf 'Docker Compose plugin is not available\n' >&2
        return 1
    }
    compose_command=(docker compose --file "${compose_file}")
    "${compose_command[@]}" config --quiet || {
        printf 'Docker Compose configuration is invalid: %s\n' \
            "${compose_file}" >&2
        return 1
    }
    docker info --format '{{.ServerVersion}}' >/dev/null || {
        printf 'Docker daemon is not available\n' >&2
        return 1
    }

    printf '\nStarting Docker Compose project from %s\n' "${compose_file}"
    "${compose_command[@]}" up --detach
    printf 'Docker Compose project started\n'
}
