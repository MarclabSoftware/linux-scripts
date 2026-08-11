#!/usr/bin/env bash

# Provisioning module: TAR backup restore.
#
# Restores a trusted archive into an explicit destination during phase two.
# Member names are checked before extraction to reject absolute paths and
# parent-directory traversal. Archives remain administrator-controlled input;
# special files and link metadata are intentionally preserved.
#
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

validateBackupRestoreConfiguration() {
    local variable value

    for variable in CONFIG_BACKUP_FILE_PATH CONFIG_BACKUP_RESTORE_DESTINATION; do
        [[ -v "${variable}" ]] || {
            printf 'Missing %s configuration\n' "${variable}" >&2
            return 1
        }
        value="${!variable}"
        [[ "${value}" == /* && "${value}" != *[$'\r\n']* ]] || {
            printf '%s must be a single-line absolute path\n' \
                "${variable}" >&2
            return 1
        }
    done
}

validateBackupArchive() {
    local archive="$1"
    local listing member component
    local validation_error=""
    local -a components=()

    [[ -f "${archive}" && -r "${archive}" ]] || {
        printf 'Backup archive is not a readable regular file: %s\n' \
            "${archive}" >&2
        return 1
    }

    listing="$(mktemp)" || return
    if ! tar --list --quoting-style=escape --file "${archive}" \
        >"${listing}"; then
        rm -f -- "${listing}"
        printf 'Backup archive is invalid: %s\n' "${archive}" >&2
        return 1
    fi

    while IFS= read -r member; do
        if [[ "${member}" == /* ]]; then
            validation_error="absolute path: ${member}"
            break
        fi
        member="${member#./}"
        IFS=/ read -r -a components <<<"${member}"
        for component in "${components[@]}"; do
            if [[ "${component}" == .. ]]; then
                validation_error="parent-directory traversal: ${member}"
                break 2
            fi
        done
    done <"${listing}"
    rm -f -- "${listing}"

    [[ -z "${validation_error}" ]] || {
        printf 'Backup archive contains %s\n' "${validation_error}" >&2
        return 1
    }
}

restoreBackup() {
    local archive destination

    validateBackupRestoreConfiguration || return
    checkCommand tar || return
    archive="${CONFIG_BACKUP_FILE_PATH}"
    destination="${CONFIG_BACKUP_RESTORE_DESTINATION}"

    [[ -d "${destination}" && ! -L "${destination}" ]] || {
        printf 'Backup destination is not a real directory: %s\n' \
            "${destination}" >&2
        return 1
    }
    validateBackupArchive "${archive}" || return

    printf '\nRestoring %s into %s\n' "${archive}" "${destination}"
    tar --extract \
        --file "${archive}" \
        --directory "${destination}" \
        --numeric-owner \
        --same-owner \
        --same-permissions \
        --keep-directory-symlink
    printf 'Backup restored\n'
}
