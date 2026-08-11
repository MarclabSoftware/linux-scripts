#!/usr/bin/env bash

# Provisioning module: persistent journal limits.
#
# Installs an administrator drop-in for systemd-journald. This module does not
# change the journal storage mode: System* settings apply only when persistent
# storage under /var/log/journal is enabled.

validateJournalLimits() {
    local setting
    local value

    for setting in \
        CONFIG_JOURNAL_SYSTEM_MAX_USE \
        CONFIG_JOURNAL_SYSTEM_MAX_FILE_SIZE; do
        value="${!setting:-}"
        [[ "${value}" =~ ^[0-9]+[KMGTPE]?$ ]] || {
            printf '%s must be a size in bytes or use K, M, G, T, P or E\n' \
                "${setting}" >&2
            return 1
        }
    done
}

limitJournal() {
    local journal_conf_d="${1:-/etc/systemd/journald.conf.d}"
    local journal_conf_f="${journal_conf_d}/90-linux-scripts-journal-limits.conf"
    local legacy_conf_f="${journal_conf_d}/size.conf"
    local system_max_use="${CONFIG_JOURNAL_SYSTEM_MAX_USE:-}"
    local system_max_file_size="${CONFIG_JOURNAL_SYSTEM_MAX_FILE_SIZE:-}"
    local temporary_conf
    local configuration_changed=false

    validateJournalLimits
    install -d -m 0755 -- "${journal_conf_d}"
    temporary_conf="$(mktemp "${journal_conf_d}/.journal-limits.XXXXXX")"
    if ! printf '[Journal]\nSystemMaxUse=%s\nSystemMaxFileSize=%s\n' \
        "${system_max_use}" "${system_max_file_size}" >"${temporary_conf}" ||
        ! chmod 0644 -- "${temporary_conf}"; then
        rm -f -- "${temporary_conf}"
        return 1
    fi

    if cmp -s -- "${temporary_conf}" "${journal_conf_f}"; then
        rm -f -- "${temporary_conf}"
    else
        if ! mv -f -- "${temporary_conf}" "${journal_conf_f}"; then
            rm -f -- "${temporary_conf}"
            return 1
        fi
        configuration_changed=true
    fi

    # Remove only the drop-in written by older releases of this module.
    if [[ -e "${legacy_conf_f}" || -L "${legacy_conf_f}" ]]; then
        rm -f -- "${legacy_conf_f}"
        configuration_changed=true
    fi

    if [[ "${configuration_changed}" == false ]]; then
        printf 'Journal limits are already current: %s\n' "${journal_conf_f}"
        return 0
    fi

    systemctl reload-or-restart systemd-journald.service
    printf 'Journal limits updated: %s\n' "${journal_conf_f}"
}
