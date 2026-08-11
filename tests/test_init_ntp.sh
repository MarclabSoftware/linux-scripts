#!/usr/bin/env bash

# Validate timesyncd and Chrony provisioning without changing the host clock.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=src/init/scripts/ntp.sh
. "${REPO_ROOT}/src/init/scripts/ntp.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

CONFIG_NTP_BACKEND="timesyncd"
CONFIG_NTP_SERVERS="192.0.2.1"
CONFIG_NTP_FALLBACK_SERVERS="time.cloudflare.com"
CONFIG_NTP_CHRONY_NTS=true
CONFIG_NTP_CHRONY_MIN_SOURCES="3"
CONFIG_NTP_CHRONY_MAX_UPDATE_SKEW="100"
CONFIG_NTP_CHRONY_LOG_CHANGE="0.5"
validateNtpConfiguration
unset CONFIG_NTP_FALLBACK_SERVERS
expect_failure validateNtpConfiguration
CONFIG_NTP_FALLBACK_SERVERS="time.cloudflare.com"

CONFIG_NTP_BACKEND="invalid"
expect_failure validateNtpConfiguration
CONFIG_NTP_BACKEND="timesyncd"
CONFIG_NTP_SERVERS=$'time.example\nallow 0/0'
expect_failure validateNtpConfiguration

CONFIG_NTP_BACKEND="chrony"
CONFIG_NTP_SERVERS="time.cloudflare.com nts.netnod.se ptbtime4.ptb.de"
unset CONFIG_NTP_FALLBACK_SERVERS
validateNtpConfiguration
CONFIG_NTP_CHRONY_MIN_SOURCES="4"
expect_failure validateNtpConfiguration
CONFIG_NTP_CHRONY_MIN_SOURCES="3"
CONFIG_NTP_CHRONY_NTS="yes"
expect_failure validateNtpConfiguration
CONFIG_NTP_CHRONY_NTS=true
CONFIG_NTP_CHRONY_MAX_UPDATE_SKEW="100; reboot"
expect_failure validateNtpConfiguration
CONFIG_NTP_CHRONY_MAX_UPDATE_SKEW="100"

systemctl_log="${TEST_TMP}/systemctl.log"
chronyd_log="${TEST_TMP}/chronyd.log"
test_package_manager="apt"
config_mode=""

systemctl() {
    printf '%s\n' "$*" >>"${systemctl_log}"
    case "$1" in
        cat | disable | enable | restart) return 0 ;;
        is-active) [[ "$2" == --quiet ]] ;;
        *) return 2 ;;
    esac
}

chronyd() {
    printf '%s\n' "$*" >>"${chronyd_log}"
    [[ "$1" == -p && "$2" == -f && -r "$3" ]]
}

selected_package_manager() {
    printf '%s\n' "${test_package_manager}"
}

CONFIG_NTP_BACKEND="timesyncd"
CONFIG_NTP_SERVERS="192.0.2.1"
CONFIG_NTP_FALLBACK_SERVERS=""
timesyncd_root="${TEST_TMP}/timesyncd"
customNtp "${timesyncd_root}" >/dev/null
timesyncd_config="${timesyncd_root}/etc/systemd/timesyncd.conf.d/90-linux-scripts-ntp.conf"
grep -qxF 'NTP=192.0.2.1' "${timesyncd_config}"
grep -qxF 'FallbackNTP=' "${timesyncd_config}"
grep -qxF 'enable systemd-timesyncd.service' "${systemctl_log}"
grep -qxF 'restart systemd-timesyncd.service' "${systemctl_log}"
grep -qxF 'disable chronyd.service' "${systemctl_log}"
config_mode="$(stat -c '%a' -- "${timesyncd_config}")"
[[ "${config_mode}" == 644 ]]

: >"${systemctl_log}"
CONFIG_NTP_BACKEND="chrony"
CONFIG_NTP_SERVERS="time.cloudflare.com nts.netnod.se ptbtime4.ptb.de"
CONFIG_NTP_FALLBACK_SERVERS=""
chrony_root="${TEST_TMP}/chrony-apt"
customNtp "${chrony_root}" >/dev/null
chrony_config="${chrony_root}/etc/chrony/chrony.conf"
grep -qxF 'server time.cloudflare.com iburst nts' "${chrony_config}"
grep -qxF 'server nts.netnod.se iburst nts' "${chrony_config}"
grep -qxF 'authselectmode require' "${chrony_config}"
grep -qxF 'minsources 3' "${chrony_config}"
grep -qxF 'driftfile /var/lib/chrony/chrony.drift' "${chrony_config}"
grep -qxF 'leapsectz right/UTC' "${chrony_config}"
grep -qxF 'port 0' "${chrony_config}"
grep -qxF 'cmdport 0' "${chrony_config}"
grep -qxF 'enable chronyd.service' "${systemctl_log}"
grep -qxF 'restart chronyd.service' "${systemctl_log}"
grep -qxF 'disable systemd-timesyncd.service' "${systemctl_log}"
config_mode="$(stat -c '%a' -- "${chrony_config}")"
[[ "${config_mode}" == 644 ]]
grep -qE '^-p -f /tmp/' "${chronyd_log}"

test_package_manager="pacman"
pacman_config="${TEST_TMP}/chrony-pacman.conf"
renderChronyConfig "${test_package_manager}" >"${pacman_config}"
grep -qxF 'driftfile /var/lib/chrony/drift' "${pacman_config}"
grep -qxF 'leapseclist /usr/share/zoneinfo/leap-seconds.list' \
    "${pacman_config}"

CONFIG_NTP_CHRONY_NTS=false
renderChronyConfig "${test_package_manager}" >"${pacman_config}"
if grep -qE ' iburst nts$|^authselectmode ' "${pacman_config}"; then
    printf 'NTS directives rendered while NTS was disabled\n' >&2
    exit 1
fi

printf 'init NTP tests passed\n'
