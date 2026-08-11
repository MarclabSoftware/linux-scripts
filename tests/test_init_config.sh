#!/usr/bin/env bash

# Validate the public init configuration contract without changing the host.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly INIT_SCRIPT="${REPO_ROOT}/src/init/init.sh"

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

make_config() {
    local target="$1"

    mkdir -p -- "${target%/*}"
    cp -- "${REPO_ROOT}/src/init/init.env.example" "${target}"
    chmod 0600 -- "${target}"
}

expect_valid() {
    local config_file="$1"

    "${INIT_SCRIPT}" --config "${config_file}" --check-config |
        grep -Fx 'init configuration is valid' >/dev/null
}

expect_invalid() {
    local config_file="$1"

    if "${INIT_SCRIPT}" --config "${config_file}" \
        --check-config >/dev/null 2>&1; then
        printf 'init accepted invalid configuration: %s\n' "${config_file}" >&2
        exit 1
    fi
}

config_file="${TEST_TMP}/private config/init.env"
make_config "${config_file}"
expect_valid "${config_file}"

# CLI configuration takes precedence over an invalid environment path.
INIT_ENV_FILE="${TEST_TMP}/missing.env" \
    "${INIT_SCRIPT}" --check-config --config "${config_file}" >/dev/null

# Help must remain available without a configuration file.
INIT_ENV_FILE="${TEST_TMP}/missing.env" "${INIT_SCRIPT}" --help >/dev/null

# Private read-only files are valid; any group/other access is rejected.
chmod 0400 -- "${config_file}"
expect_valid "${config_file}"
for insecure_mode in 0644 0660 0666; do
    chmod "${insecure_mode}" -- "${config_file}"
    expect_invalid "${config_file}"
done
chmod 0600 -- "${config_file}"

invalid_manager="${TEST_TMP}/invalid-manager.env"
make_config "${invalid_manager}"
sed -i 's/^CONFIG_PACKAGE_MANAGER=.*/CONFIG_PACKAGE_MANAGER="dnf"/' \
    "${invalid_manager}"
expect_invalid "${invalid_manager}"

invalid_flag="${TEST_TMP}/invalid-flag.env"
make_config "${invalid_flag}"
sed -i 's/^CONFIG_INIT_RFKILL=.*/CONFIG_INIT_RFKILL=ask/' "${invalid_flag}"
expect_invalid "${invalid_flag}"

missing_flag="${TEST_TMP}/missing-flag.env"
make_config "${missing_flag}"
sed -i '/^CONFIG_INIT_RFKILL=/d' "${missing_flag}"
expect_invalid "${missing_flag}"

valid_rfkill="${TEST_TMP}/valid-rfkill.env"
make_config "${valid_rfkill}"
sed -i \
    -e 's/^CONFIG_INIT_RFKILL=.*/CONFIG_INIT_RFKILL=true/' \
    -e 's/^CONFIG_RFKILL_TARGETS=.*/CONFIG_RFKILL_TARGETS="wlan, bluetooth,2"/' \
    "${valid_rfkill}"
expect_valid "${valid_rfkill}"

invalid_rfkill="${TEST_TMP}/invalid-rfkill.env"
make_config "${invalid_rfkill}"
sed -i \
    -e 's/^CONFIG_INIT_RFKILL=.*/CONFIG_INIT_RFKILL=true/' \
    -e 's/^CONFIG_RFKILL_TARGETS=.*/CONFIG_RFKILL_TARGETS="wlan0"/' \
    "${invalid_rfkill}"
expect_invalid "${invalid_rfkill}"

empty_rfkill="${TEST_TMP}/empty-rfkill.env"
make_config "${empty_rfkill}"
sed -i \
    -e 's/^CONFIG_INIT_RFKILL=.*/CONFIG_INIT_RFKILL=true/' \
    -e 's/^CONFIG_RFKILL_TARGETS=.*/CONFIG_RFKILL_TARGETS=""/' \
    "${empty_rfkill}"
expect_invalid "${empty_rfkill}"

valid_journal="${TEST_TMP}/valid-journal.env"
make_config "${valid_journal}"
sed -i \
    -e 's/^CONFIG_INIT_JOURNAL_LIMIT=.*/CONFIG_INIT_JOURNAL_LIMIT=true/' \
    -e 's/^CONFIG_JOURNAL_SYSTEM_MAX_USE=.*/CONFIG_JOURNAL_SYSTEM_MAX_USE="250M"/' \
    -e 's/^CONFIG_JOURNAL_SYSTEM_MAX_FILE_SIZE=.*/CONFIG_JOURNAL_SYSTEM_MAX_FILE_SIZE="50M"/' \
    "${valid_journal}"
expect_valid "${valid_journal}"

invalid_journal="${TEST_TMP}/invalid-journal.env"
make_config "${invalid_journal}"
sed -i \
    -e 's/^CONFIG_INIT_JOURNAL_LIMIT=.*/CONFIG_INIT_JOURNAL_LIMIT=true/' \
    -e 's/^CONFIG_JOURNAL_SYSTEM_MAX_USE=.*/CONFIG_JOURNAL_SYSTEM_MAX_USE="250MB"/' \
    "${invalid_journal}"
expect_invalid "${invalid_journal}"

valid_memory="${TEST_TMP}/valid-memory.env"
make_config "${valid_memory}"
sed -i \
    -e 's/^CONFIG_INIT_MEMORY_CONFIGURE=.*/CONFIG_INIT_MEMORY_CONFIGURE=true/' \
    -e 's/^CONFIG_MEMORY_ZRAM_ENABLED=.*/CONFIG_MEMORY_ZRAM_ENABLED=true/' \
    -e 's|^CONFIG_MEMORY_ZRAM_SIZE=.*|CONFIG_MEMORY_ZRAM_SIZE="ram / 4"|' \
    "${valid_memory}"
expect_valid "${valid_memory}"

invalid_memory="${TEST_TMP}/invalid-memory.env"
make_config "${invalid_memory}"
sed -i \
    -e 's/^CONFIG_INIT_MEMORY_CONFIGURE=.*/CONFIG_INIT_MEMORY_CONFIGURE=true/' \
    -e 's/^CONFIG_MEMORY_SWAPPINESS=.*/CONFIG_MEMORY_SWAPPINESS="201"/' \
    "${invalid_memory}"
expect_invalid "${invalid_memory}"

valid_network="${TEST_TMP}/valid-network.env"
make_config "${valid_network}"
sed -i \
    -e 's/^CONFIG_INIT_NETWORK_CONFIGURE=.*/CONFIG_INIT_NETWORK_CONFIGURE=true/' \
    -e 's/^CONFIG_NETWORK_IPV6_FORWARDING=.*/CONFIG_NETWORK_IPV6_FORWARDING=true/' \
    -e 's/^CONFIG_NETWORK_RESERVED_PORTS=.*/CONFIG_NETWORK_RESERVED_PORTS="40000,41000-41010"/' \
    "${valid_network}"
expect_valid "${valid_network}"

invalid_network="${TEST_TMP}/invalid-network.env"
make_config "${invalid_network}"
sed -i \
    -e 's/^CONFIG_INIT_NETWORK_CONFIGURE=.*/CONFIG_INIT_NETWORK_CONFIGURE=true/' \
    -e 's/^CONFIG_NETWORK_RESERVED_PORTS=.*/CONFIG_NETWORK_RESERVED_PORTS="40000,70000"/' \
    "${invalid_network}"
expect_invalid "${invalid_network}"

valid_fstrim="${TEST_TMP}/valid-fstrim.env"
make_config "${valid_fstrim}"
sed -i 's/^CONFIG_INIT_FSTRIM_ENABLE=.*/CONFIG_INIT_FSTRIM_ENABLE=true/' \
    "${valid_fstrim}"
printf '%s\n' \
    'CONFIG_FSTRIM_USB_UNMAP_IDS=(' \
    '    "1234:abcd"' \
    ')' >>"${valid_fstrim}"
expect_valid "${valid_fstrim}"

invalid_fstrim="${TEST_TMP}/invalid-fstrim.env"
make_config "${invalid_fstrim}"
sed -i 's/^CONFIG_INIT_FSTRIM_ENABLE=.*/CONFIG_INIT_FSTRIM_ENABLE=true/' \
    "${invalid_fstrim}"
printf '%s\n' \
    'CONFIG_FSTRIM_USB_UNMAP_IDS=(' \
    '    "usb-device"' \
    ')' >>"${invalid_fstrim}"
expect_invalid "${invalid_fstrim}"

valid_ntp="${TEST_TMP}/valid-ntp.env"
make_config "${valid_ntp}"
sed -i 's/^CONFIG_INIT_NTP_CUSTOMIZATION=.*/CONFIG_INIT_NTP_CUSTOMIZATION=true/' \
    "${valid_ntp}"
expect_valid "${valid_ntp}"

valid_timesyncd="${TEST_TMP}/valid-timesyncd.env"
make_config "${valid_timesyncd}"
sed -i \
    -e 's/^CONFIG_INIT_NTP_CUSTOMIZATION=.*/CONFIG_INIT_NTP_CUSTOMIZATION=true/' \
    -e 's/^CONFIG_NTP_BACKEND=.*/CONFIG_NTP_BACKEND="timesyncd"/' \
    -e 's/^CONFIG_NTP_SERVERS=.*/CONFIG_NTP_SERVERS="192.0.2.1"/' \
    "${valid_timesyncd}"
expect_valid "${valid_timesyncd}"

invalid_ntp="${TEST_TMP}/invalid-ntp.env"
make_config "${invalid_ntp}"
sed -i \
    -e 's/^CONFIG_INIT_NTP_CUSTOMIZATION=.*/CONFIG_INIT_NTP_CUSTOMIZATION=true/' \
    -e 's/^CONFIG_NTP_CHRONY_MIN_SOURCES=.*/CONFIG_NTP_CHRONY_MIN_SOURCES="7"/' \
    "${invalid_ntp}"
expect_invalid "${invalid_ntp}"

valid_resolved="${TEST_TMP}/valid-resolved.env"
make_config "${valid_resolved}"
sed -i \
    -e 's/^CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE=.*/CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE=true/' \
    -e 's/^CONFIG_RESOLVED_STUB_LISTENER=.*/CONFIG_RESOLVED_STUB_LISTENER="yes"/' \
    -e 's/^CONFIG_RESOLVED_RESOLV_CONF_MODE=.*/CONFIG_RESOLVED_RESOLV_CONF_MODE="stub"/' \
    "${valid_resolved}"
expect_valid "${valid_resolved}"

invalid_resolved="${TEST_TMP}/invalid-resolved.env"
make_config "${invalid_resolved}"
sed -i \
    -e 's/^CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE=.*/CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE=true/' \
    -e 's/^CONFIG_RESOLVED_RESOLV_CONF_MODE=.*/CONFIG_RESOLVED_RESOLV_CONF_MODE="stub"/' \
    "${invalid_resolved}"
expect_invalid "${invalid_resolved}"

valid_docker_daemon="${TEST_TMP}/valid-docker-daemon.env"
make_config "${valid_docker_daemon}"
sed -i \
    -e 's/^CONFIG_INIT_DOCKER_DAEMON_CONFIGURE=.*/CONFIG_INIT_DOCKER_DAEMON_CONFIGURE=true/' \
    -e 's/^CONFIG_INIT_SRV_DOCKER_ENABLE=.*/CONFIG_INIT_SRV_DOCKER_ENABLE=true/' \
    -e 's/^CONFIG_DOCKER_IPV6=.*/CONFIG_DOCKER_IPV6=true/' \
    -e 's|^CONFIG_DOCKER_FIXED_CIDR_V6=.*|CONFIG_DOCKER_FIXED_CIDR_V6="2001:db8:1::/64"|' \
    "${valid_docker_daemon}"
expect_valid "${valid_docker_daemon}"

invalid_docker_daemon="${TEST_TMP}/invalid-docker-daemon.env"
make_config "${invalid_docker_daemon}"
sed -i \
    -e 's/^CONFIG_INIT_DOCKER_DAEMON_CONFIGURE=.*/CONFIG_INIT_DOCKER_DAEMON_CONFIGURE=true/' \
    -e 's/^CONFIG_INIT_SRV_DOCKER_ENABLE=.*/CONFIG_INIT_SRV_DOCKER_ENABLE=true/' \
    -e 's/^CONFIG_DOCKER_EXPERIMENTAL=.*/CONFIG_DOCKER_EXPERIMENTAL=false/' \
    "${invalid_docker_daemon}"
expect_invalid "${invalid_docker_daemon}"

valid_docker_login="${TEST_TMP}/valid-docker-login.env"
make_config "${valid_docker_login}"
sed -i \
    -e 's/^CONFIG_INIT_DOCKER_LOGIN=.*/CONFIG_INIT_DOCKER_LOGIN=true/' \
    -e 's/^CONFIG_DOCKER_REGISTRY=.*/CONFIG_DOCKER_REGISTRY="registry.example.com:5443"/' \
    -e 's/^CONFIG_DOCKER_USERNAME=.*/CONFIG_DOCKER_USERNAME="deploy-user"/' \
    "${valid_docker_login}"
expect_valid "${valid_docker_login}"

invalid_docker_login="${TEST_TMP}/invalid-docker-login.env"
make_config "${invalid_docker_login}"
sed -i \
    -e 's/^CONFIG_INIT_DOCKER_LOGIN=.*/CONFIG_INIT_DOCKER_LOGIN=true/' \
    -e 's|^CONFIG_DOCKER_REGISTRY=.*|CONFIG_DOCKER_REGISTRY="https://registry.example.com/project"|' \
    "${invalid_docker_login}"
expect_invalid "${invalid_docker_login}"

valid_docker_bridge="${TEST_TMP}/valid-docker-bridge.env"
make_config "${valid_docker_bridge}"
sed -i \
    's/^CONFIG_INIT_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE=.*/CONFIG_INIT_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE=true/' \
    "${valid_docker_bridge}"
expect_valid "${valid_docker_bridge}"

valid_rpi_eeprom="${TEST_TMP}/valid-rpi-eeprom.env"
make_config "${valid_rpi_eeprom}"
sed -i \
    -e 's/^CONFIG_INIT_RPI_EEPROM_UPDATE=.*/CONFIG_INIT_RPI_EEPROM_UPDATE=true/' \
    -e 's/^CONFIG_RPI_EEPROM_RELEASE=.*/CONFIG_RPI_EEPROM_RELEASE="latest"/' \
    "${valid_rpi_eeprom}"
expect_valid "${valid_rpi_eeprom}"

invalid_rpi_eeprom="${TEST_TMP}/invalid-rpi-eeprom.env"
make_config "${invalid_rpi_eeprom}"
sed -i \
    -e 's/^CONFIG_INIT_RPI_EEPROM_UPDATE=.*/CONFIG_INIT_RPI_EEPROM_UPDATE=true/' \
    -e 's/^CONFIG_RPI_EEPROM_RELEASE=.*/CONFIG_RPI_EEPROM_RELEASE="beta"/' \
    "${invalid_rpi_eeprom}"
expect_invalid "${invalid_rpi_eeprom}"

valid_rpi_boot="${TEST_TMP}/valid-rpi-boot.env"
make_config "${valid_rpi_boot}"
sed -i \
    's/^CONFIG_INIT_RPI_BOOT_CONFIGURE=.*/CONFIG_INIT_RPI_BOOT_CONFIGURE=true/' \
    "${valid_rpi_boot}"
printf '%s\n' \
    'CONFIG_RPI_BOOT_SETTINGS=(' \
    '    "[pi5]"' \
    '    "arm_freq_min=600"' \
    ')' >>"${valid_rpi_boot}"
expect_valid "${valid_rpi_boot}"

empty_rpi_boot="${TEST_TMP}/empty-rpi-boot.env"
make_config "${empty_rpi_boot}"
sed -i \
    's/^CONFIG_INIT_RPI_BOOT_CONFIGURE=.*/CONFIG_INIT_RPI_BOOT_CONFIGURE=true/' \
    "${empty_rpi_boot}"
expect_invalid "${empty_rpi_boot}"

valid_user_groups="${TEST_TMP}/valid-user-groups.env"
make_config "${valid_user_groups}"
sed -i \
    -e 's/^CONFIG_INIT_USER_ADD_TO_GROUPS=.*/CONFIG_INIT_USER_ADD_TO_GROUPS=true/' \
    -e 's/^CONFIG_USER_GROUPS_TO_ADD=.*/CONFIG_USER_GROUPS_TO_ADD="wheel, docker, wheel"/' \
    "${valid_user_groups}"
expect_valid "${valid_user_groups}"

invalid_user_groups="${TEST_TMP}/invalid-user-groups.env"
make_config "${invalid_user_groups}"
sed -i \
    -e 's/^CONFIG_INIT_USER_ADD_TO_GROUPS=.*/CONFIG_INIT_USER_ADD_TO_GROUPS=true/' \
    -e 's/^CONFIG_USER_GROUPS_TO_ADD=.*/CONFIG_USER_GROUPS_TO_ADD="wheel,,docker"/' \
    "${invalid_user_groups}"
expect_invalid "${invalid_user_groups}"

valid_ssh="${TEST_TMP}/valid-ssh.env"
make_config "${valid_ssh}"
sed -i \
    -e 's/^CONFIG_INIT_SSH_HARDENING=.*/CONFIG_INIT_SSH_HARDENING=true/' \
    -e 's/^CONFIG_SSH_PORT=.*/CONFIG_SSH_PORT="2222"/' \
    -e 's/^CONFIG_SSH_ADDRESS_FAMILY=.*/CONFIG_SSH_ADDRESS_FAMILY="inet"/' \
    "${valid_ssh}"
expect_valid "${valid_ssh}"

invalid_ssh_port="${TEST_TMP}/invalid-ssh-port.env"
make_config "${invalid_ssh_port}"
sed -i \
    -e 's/^CONFIG_INIT_SSH_HARDENING=.*/CONFIG_INIT_SSH_HARDENING=true/' \
    -e 's/^CONFIG_SSH_PORT=.*/CONFIG_SSH_PORT="70000"/' \
    "${invalid_ssh_port}"
expect_invalid "${invalid_ssh_port}"

invalid_ssh_rotation="${TEST_TMP}/invalid-ssh-rotation.env"
make_config "${invalid_ssh_rotation}"
sed -i \
    -e 's/^CONFIG_INIT_SSH_HARDENING=.*/CONFIG_INIT_SSH_HARDENING=true/' \
    -e 's/^CONFIG_SSH_FORCE_HOST_KEY_ROTATION=.*/CONFIG_SSH_FORCE_HOST_KEY_ROTATION=once/' \
    "${invalid_ssh_rotation}"
expect_invalid "${invalid_ssh_rotation}"

invalid_ssh_directive="${TEST_TMP}/invalid-ssh-directive.env"
make_config "${invalid_ssh_directive}"
sed -i \
    's/^CONFIG_INIT_SSH_HARDENING=.*/CONFIG_INIT_SSH_HARDENING=true/' \
    "${invalid_ssh_directive}"
printf '%s\n' \
    'CONFIG_SSH_EXTRA_DIRECTIVES=(' \
    '    "Match User root"' \
    ')' >>"${invalid_ssh_directive}"
expect_invalid "${invalid_ssh_directive}"

relative_restore="${TEST_TMP}/relative-restore.env"
make_config "${relative_restore}"
sed -i \
    -e 's/^CONFIG_INIT_BACKUP_RESTORE=.*/CONFIG_INIT_BACKUP_RESTORE=true/' \
    -e 's|^CONFIG_BACKUP_FILE_PATH=.*|CONFIG_BACKUP_FILE_PATH="backup.tar"|' \
    "${relative_restore}"
expect_invalid "${relative_restore}"

relative_restore_destination="${TEST_TMP}/relative-restore-destination.env"
make_config "${relative_restore_destination}"
sed -i \
    -e 's/^CONFIG_INIT_BACKUP_RESTORE=.*/CONFIG_INIT_BACKUP_RESTORE=true/' \
    -e 's|^CONFIG_BACKUP_FILE_PATH=.*|CONFIG_BACKUP_FILE_PATH="/tmp/backup.tar"|' \
    -e 's|^CONFIG_BACKUP_RESTORE_DESTINATION=.*|CONFIG_BACKUP_RESTORE_DESTINATION="restore"|' \
    "${relative_restore_destination}"
expect_invalid "${relative_restore_destination}"

relative_compose="${TEST_TMP}/relative-compose.env"
make_config "${relative_compose}"
sed -i \
    -e 's/^CONFIG_INIT_DOCKER_COMPOSE_START=.*/CONFIG_INIT_DOCKER_COMPOSE_START=true/' \
    -e 's|^CONFIG_DOCKER_COMPOSE_FILE_PATH=.*|CONFIG_DOCKER_COMPOSE_FILE_PATH="compose.yaml"|' \
    "${relative_compose}"
expect_invalid "${relative_compose}"

printf 'init configuration tests passed\n'
