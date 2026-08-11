#!/usr/bin/env bash

# Validate memory and zram configuration without touching the running host.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

# shellcheck source=../src/init/scripts/utils.sh
. "${REPO_ROOT}/src/init/scripts/utils.sh"
# shellcheck source=../src/init/scripts/memory.sh
. "${REPO_ROOT}/src/init/scripts/memory.sh"

CONFIG_MEMORY_SWAPPINESS="180"
CONFIG_MEMORY_PAGE_CLUSTER="0"
CONFIG_MEMORY_OVERCOMMIT_MEMORY="1"
CONFIG_MEMORY_ZRAM_ENABLED=true
CONFIG_MEMORY_ZRAM_SIZE="ram / 2"
CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM="zstd"
validateMemoryConfiguration

expect_invalid_memory_configuration() {
    local invalid_description="$1"
    local validation_status

    set +e
    validateMemoryConfiguration 2>/dev/null
    validation_status=$?
    set -e
    if ((validation_status == 0)); then
        printf 'invalid memory configuration was accepted: %s\n' \
            "${invalid_description}" >&2
        exit 1
    fi
}

for invalid_swappiness in "" "-1" "201" "10.5"; do
    CONFIG_MEMORY_SWAPPINESS="${invalid_swappiness}"
    expect_invalid_memory_configuration \
        "swappiness ${invalid_swappiness:-<empty>}"
done
CONFIG_MEMORY_SWAPPINESS="180"

for invalid_page_cluster in "" "-1" "32" "1.5"; do
    CONFIG_MEMORY_PAGE_CLUSTER="${invalid_page_cluster}"
    expect_invalid_memory_configuration \
        "page-cluster ${invalid_page_cluster:-<empty>}"
done
CONFIG_MEMORY_PAGE_CLUSTER="0"

for invalid_overcommit in "-1" "3" "always"; do
    CONFIG_MEMORY_OVERCOMMIT_MEMORY="${invalid_overcommit}"
    expect_invalid_memory_configuration \
        "overcommit memory ${invalid_overcommit}"
done
CONFIG_MEMORY_OVERCOMMIT_MEMORY="1"

CONFIG_MEMORY_ZRAM_ENABLED=maybe
expect_invalid_memory_configuration 'zram boolean'
CONFIG_MEMORY_ZRAM_ENABLED=true

for invalid_size in "" "ram / 2; reboot" $'ram / 2\nram / 4'; do
    CONFIG_MEMORY_ZRAM_SIZE="${invalid_size}"
    expect_invalid_memory_configuration 'zram size'
done
CONFIG_MEMORY_ZRAM_SIZE="ram / 2"

CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM="zstd;reboot"
expect_invalid_memory_configuration 'compression algorithm'
CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM="zstd"

command_log="${TEST_TMP}/commands.log"
readonly command_log

checkCommand() {
    return 0
}

sysctl() {
    printf 'sysctl %s\n' "$*" >>"${command_log}"
}

systemctl() {
    printf 'systemctl %s\n' "$*" >>"${command_log}"
}

legacy_file="${TEST_TMP}/etc/sysctl.d/swappiness.conf"
mkdir -p -- "${legacy_file%/*}"
printf 'vm.swappiness=10\n' >"${legacy_file}"

configureMemory "${TEST_TMP}" >/dev/null

sysctl_file="${TEST_TMP}/etc/sysctl.d/90-linux-scripts-memory.conf"
zram_file="${TEST_TMP}/etc/systemd/zram-generator.conf.d/90-linux-scripts.conf"
zswap_unit="${TEST_TMP}/etc/systemd/system/linux-scripts-zswap-disable.service"
zram_dropin="${TEST_TMP}/etc/systemd/system/systemd-zram-setup@.service.d/90-linux-scripts-zswap.conf"

[[ "$(<"${sysctl_file}")" == $'# Managed by linux-scripts init.\nvm.swappiness = 180\nvm.page-cluster = 0\nvm.overcommit_memory = 1' ]]
grep -qxF 'zram-size = ram / 2' "${zram_file}"
grep -qxF 'compression-algorithm = zstd' "${zram_file}"
grep -qxF 'swap-priority = 100' "${zram_file}"
grep -qxF "ExecStart=/bin/sh -c 'printf N > /sys/module/zswap/parameters/enabled'" \
    "${zswap_unit}"
grep -qxF 'Requires=linux-scripts-zswap-disable.service' "${zram_dropin}"
[[ ! -e "${legacy_file}" ]]
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${zswap_unit}"
fi

for config_file in \
    "${sysctl_file}" \
    "${zram_file}" \
    "${zswap_unit}" \
    "${zram_dropin}"; do
    config_mode="$(stat -c '%a' -- "${config_file}")"
    [[ "${config_mode}" == 644 ]]
done

grep -qxF "sysctl --load=${sysctl_file}" "${command_log}"
grep -qxF 'systemctl disable dphys-swapfile.service' "${command_log}"
grep -qxF 'systemctl daemon-reload' "${command_log}"

# An empty compressor delegates the choice to the kernel.
CONFIG_MEMORY_ZRAM_COMPRESSION_ALGORITHM=""
CONFIG_MEMORY_OVERCOMMIT_MEMORY=""
CONFIG_MEMORY_ZRAM_SIZE="ram / 4"
configureMemory "${TEST_TMP}" >/dev/null
grep -qxF 'zram-size = ram / 4' "${zram_file}"
if grep -q '^vm.overcommit_memory' "${sysctl_file}"; then
    printf 'empty overcommit policy still produced a sysctl setting\n' >&2
    exit 1
fi
if grep -q '^compression-algorithm' "${zram_file}"; then
    printf 'empty compressor still produced a zram setting\n' >&2
    exit 1
fi

# Disabling zram removes only files owned by this module.
CONFIG_MEMORY_ZRAM_ENABLED=false
configureMemory "${TEST_TMP}" >/dev/null
[[ ! -e "${zram_file}" ]]
[[ ! -e "${zswap_unit}" ]]
[[ ! -e "${zram_dropin}" ]]
[[ -e "${sysctl_file}" ]]

printf 'init memory tests passed\n'
