#!/usr/bin/env bash

# Validate persistent journald configuration without changing the real service.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=../src/init/scripts/journal_limit.sh
. "${REPO_ROOT}/src/init/scripts/journal_limit.sh"

CONFIG_JOURNAL_SYSTEM_MAX_USE="250M"
CONFIG_JOURNAL_SYSTEM_MAX_FILE_SIZE="50M"
validateJournalLimits

for invalid_size in "" "250MB" "-1M" "1.5G"; do
    CONFIG_JOURNAL_SYSTEM_MAX_USE="${invalid_size}"
    set +e
    validateJournalLimits 2>/dev/null
    validation_status=$?
    set -e
    if ((validation_status == 0)); then
        printf 'invalid journal size was accepted: %s\n' \
            "${invalid_size:-<empty>}" >&2
        exit 1
    fi
done

CONFIG_JOURNAL_SYSTEM_MAX_USE="250M"
systemctl_log="${TEST_TMP}/systemctl.log"
readonly systemctl_log

systemctl() {
    printf '%s\n' "$*" >>"${systemctl_log}"
}

config_dir="${TEST_TMP}/journald.conf.d"
readonly config_dir
config_file="${config_dir}/90-linux-scripts-journal-limits.conf"
readonly config_file

limitJournal "${config_dir}" >/dev/null
[[ "$(<"${config_file}")" == $'[Journal]\nSystemMaxUse=250M\nSystemMaxFileSize=50M' ]]
config_mode="$(stat -c '%a' -- "${config_file}")"
[[ "${config_mode}" == 644 ]]
grep -qxF 'reload-or-restart systemd-journald.service' "${systemctl_log}"

# An unchanged drop-in must not reload or restart journald again.
: >"${systemctl_log}"
limitJournal "${config_dir}" >/dev/null
[[ ! -s "${systemctl_log}" ]]

# Removing the legacy file is a configuration change and must reload journald.
legacy_file="${config_dir}/size.conf"
printf '[Journal]\nSystemMaxUse=1G\n' >"${legacy_file}"
limitJournal "${config_dir}" >/dev/null
[[ ! -e "${legacy_file}" ]]
grep -qxF 'reload-or-restart systemd-journald.service' "${systemctl_log}"

printf 'init journal-limit tests passed\n'
