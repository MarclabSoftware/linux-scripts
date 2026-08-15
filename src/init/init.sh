#!/usr/bin/env bash

# Two-phase Linux host provisioner.
#
# Phase one fully updates the operating system before changing host
# configuration, then records the current boot ID. After a real reboot, phase
# two performs the operations that depend on the updated boot, network, user
# groups and services. The temporary state is removed after phase two so the
# provisioner remains safely reusable.
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail
umask 077

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_D="${SCRIPT_PATH%/*}"
readonly SCRIPT_D

readonly DEFAULT_CONFIG_F="${SCRIPT_D}/init.env"
readonly STATE_F="${INIT_STATE_FILE:-/var/lib/linux-scripts/init.state}"
readonly BOOT_ID_F="${INIT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
readonly LOCK_F="${INIT_LOCK_FILE:-/run/lock/linux-scripts-init.lock}"

die() {
    printf 'init: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        'Usage: init.sh [OPTIONS]' \
        '' \
        'Options:' \
        '  -c, --config FILE   Use FILE instead of the adjacent init.env' \
        '      --check-config  Validate configuration without changing the host' \
        '      --preflight     Check host prerequisites without changing the host' \
        '  -h, --help          Show this help' \
        '' \
        'Without a check option, run phase 1 or phase 2 according to the saved' \
        'boot state. Phase 1 requires a real reboot before phase 2 can run.'
}

config_file="${INIT_ENV_FILE:-${DEFAULT_CONFIG_F}}"
check_config=false
preflight=false
while (($# > 0)); do
    case "$1" in
        -c | --config)
            (($# >= 2)) || die "$1 requires a file"
            config_file="$2"
            shift 2
            ;;
        --check-config)
            check_config=true
            shift
            ;;
        --preflight)
            preflight=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done
readonly CONFIG_F="${config_file}"
readonly check_config preflight

[[ "${check_config}" != true || "${preflight}" != true ]] ||
    die "--check-config and --preflight are mutually exclusive"

[[ "${STATE_F}" == /* ]] || die "INIT_STATE_FILE must be absolute"
[[ "${BOOT_ID_F}" == /* ]] || die "INIT_BOOT_ID_FILE must be absolute"
[[ "${LOCK_F}" == /* ]] || die "INIT_LOCK_FILE must be absolute"

# shellcheck source=scripts/utils.sh
. "${SCRIPT_D}/scripts/utils.sh"

[[ -f "${CONFIG_F}" && -r "${CONFIG_F}" ]] ||
    die "configuration file is not readable: ${CONFIG_F}"
config_mode="$(stat -c '%a' "${CONFIG_F}")"
(((8#${config_mode} & 8#077) == 0)) ||
    die "configuration file must not be accessible by group or others: ${CONFIG_F}"

# init.env is trusted administrator-controlled Bash syntax. Its values remain
# shell variables and are deliberately not exported to child processes.
# shellcheck source=init.env.example
. "${CONFIG_F}"

[[ -n "${CONFIG_USER:-}" ]] || die "CONFIG_USER is required"
case "${CONFIG_PACKAGE_MANAGER:-}" in
    auto | pacman | apt) ;;
    *) die "CONFIG_PACKAGE_MANAGER must be auto, pacman or apt" ;;
esac

readonly -a INIT_FLAGS=(
    CONFIG_INIT_RFKILL
    CONFIG_INIT_JOURNAL_LIMIT
    CONFIG_INIT_MEMORY_CONFIGURE
    CONFIG_INIT_PACMAN_ENABLE_COLORS
    CONFIG_INIT_PACKAGE_CLEANUP
    CONFIG_INIT_RPI_EEPROM_UPDATE
    CONFIG_INIT_RPI_BOOT_CONFIGURE
    CONFIG_INIT_USER_ADD_TO_GROUPS
    CONFIG_INIT_USER_SUDO_WITHOUT_PWD
    CONFIG_INIT_SHELL_CONFIGURE
    CONFIG_INIT_NANO_CONFIGURE
    CONFIG_INIT_NETWORK_CONFIGURE
    CONFIG_INIT_FSTRIM_ENABLE
    CONFIG_INIT_NTP_CUSTOMIZATION
    CONFIG_INIT_SSH_KEYS_ADD
    CONFIG_INIT_SSH_HOSTS_ADD
    CONFIG_INIT_SSH_HARDENING
    CONFIG_INIT_SRV_BT_ENABLE
    CONFIG_INIT_DOCKER_DAEMON_CONFIGURE
    CONFIG_INIT_SRV_DOCKER_ENABLE
    CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE
    CONFIG_INIT_DOCKER_LOGIN
    CONFIG_INIT_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE
    CONFIG_INIT_BACKUP_RESTORE
    CONFIG_INIT_DOCKER_COMPOSE_START
)
for flag_name in "${INIT_FLAGS[@]}"; do
    [[ -v "${flag_name}" ]] || die "missing configuration flag: ${flag_name}"
    case "${!flag_name}" in
        true | false) ;;
        *) die "${flag_name} must be true or false" ;;
    esac
done

if [[ "${CONFIG_INIT_RFKILL}" == true ]]; then
    # Validate optional module inputs before --check-config can return and
    # before a real provisioning run performs the mandatory system update.
    # shellcheck source=scripts/rfkill.sh
    . "${SCRIPT_D}/scripts/rfkill.sh"
    validateRfkillTargets "${CONFIG_RFKILL_TARGETS:-}"
fi

if [[ "${CONFIG_INIT_JOURNAL_LIMIT}" == true ]]; then
    # Validate journal limits before --check-config can return and before a
    # provisioning run performs the mandatory system update.
    # shellcheck source=scripts/journal_limit.sh
    . "${SCRIPT_D}/scripts/journal_limit.sh"
    validateJournalLimits
fi

if [[ "${CONFIG_INIT_MEMORY_CONFIGURE}" == true ]]; then
    # Validate swap policy and zram-generator inputs before the mandatory
    # package update or any host configuration change.
    # shellcheck source=scripts/memory.sh
    . "${SCRIPT_D}/scripts/memory.sh"
    validateMemoryConfiguration
fi

if [[ "${CONFIG_INIT_RPI_EEPROM_UPDATE}" == true ]]; then
    # Validate the release track before the mandatory package update.
    # shellcheck source=scripts/rpi_eeprom.sh
    . "${SCRIPT_D}/scripts/rpi_eeprom.sh"
    validateRpiEepromConfiguration
fi

if [[ "${CONFIG_INIT_RPI_BOOT_CONFIGURE}" == true ]]; then
    # Validate every firmware line before changing the host.
    # shellcheck source=scripts/rpi_boot_config.sh
    . "${SCRIPT_D}/scripts/rpi_boot_config.sh"
    validateRpiBootConfiguration
fi

if [[ "${CONFIG_INIT_USER_ADD_TO_GROUPS}" == true ]]; then
    # Group existence is checked after package installation, but syntax can be
    # validated before --check-config returns or the host is changed.
    # shellcheck source=scripts/user_groups.sh
    . "${SCRIPT_D}/scripts/user_groups.sh"
    validateUserGroupConfiguration
fi

if [[ "${CONFIG_INIT_NETWORK_CONFIGURE}" == true ]]; then
    # Validate host-specific forwarding and port policy before changing the
    # host or checking runtime kernel support.
    # shellcheck source=scripts/network.sh
    . "${SCRIPT_D}/scripts/network.sh"
    validateNetworkConfiguration
fi

if [[ "${CONFIG_INIT_FSTRIM_ENABLE}" == true ]]; then
    # Validate optional USB bridge quirks before changing the host.
    # shellcheck source=scripts/fstrim.sh
    . "${SCRIPT_D}/scripts/fstrim.sh"
    validateFstrimConfiguration
fi

if [[ "${CONFIG_INIT_NTP_CUSTOMIZATION}" == true ]]; then
    # Validate the selected time daemon and its sources before package changes.
    # shellcheck source=scripts/ntp.sh
    . "${SCRIPT_D}/scripts/ntp.sh"
    validateNtpConfiguration
fi

if [[ "${CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE}" == true ]]; then
    # Validate resolver policy and resolv.conf mode before changing the host.
    # shellcheck source=scripts/systemd_resolved.sh
    . "${SCRIPT_D}/scripts/systemd_resolved.sh"
    validateSystemdResolvedConfiguration
fi

if [[ "${CONFIG_INIT_DOCKER_DAEMON_CONFIGURE}" == true ]]; then
    # Validate daemon policy before package changes. dockerd performs the
    # authoritative validation after Docker has been installed in phase one.
    # shellcheck source=scripts/docker_daemon.sh
    . "${SCRIPT_D}/scripts/docker_daemon.sh"
    validateDockerDaemonConfiguration
    [[ "${CONFIG_INIT_SRV_DOCKER_ENABLE}" == true ]] ||
        die "Docker daemon configuration requires Docker service provisioning"
fi

if [[ "${CONFIG_INIT_DOCKER_LOGIN}" == true ]]; then
    # Validate the registry target before the mandatory system update. Login
    # itself remains a phase-two interactive operation after the reboot.
    # shellcheck source=scripts/docker_login.sh
    . "${SCRIPT_D}/scripts/docker_login.sh"
    validateDockerLoginConfiguration
fi

if [[ "${CONFIG_INIT_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE}" == true ]]; then
    # Validate the Docker object name before the mandatory system update.
    # shellcheck source=scripts/docker_custom_bridge.sh
    . "${SCRIPT_D}/scripts/docker_custom_bridge.sh"
    validateCustomDockerBridgeConfiguration
fi

if [[ "${CONFIG_INIT_SSH_KEYS_ADD}" == true ]]; then
    # Validate public keys before the mandatory update or any host change.
    # shellcheck source=scripts/ssh_add_keys.sh
    . "${SCRIPT_D}/scripts/ssh_add_keys.sh"
    validateSSHKeyConfiguration
fi

if [[ "${CONFIG_INIT_SSH_HOSTS_ADD}" == true ]]; then
    # Validate the trusted host-key inventory before installing it globally.
    # shellcheck source=scripts/ssh_add_hosts.sh
    . "${SCRIPT_D}/scripts/ssh_add_hosts.sh"
    validateSSHKnownHostsConfiguration
fi

if [[ "${CONFIG_INIT_SSH_HARDENING}" == true ]]; then
    # Validate host-specific SSH policy before changing the host.
    # shellcheck source=scripts/ssh_hardening.sh
    . "${SCRIPT_D}/scripts/ssh_hardening.sh"
    validateSSHHardeningConfiguration
fi

if [[ "${CONFIG_INIT_BACKUP_RESTORE}" == true ]]; then
    # Validate restore paths before the mandatory system update. Archive
    # contents are inspected immediately before phase-two extraction.
    # shellcheck source=scripts/backup_restore.sh
    . "${SCRIPT_D}/scripts/backup_restore.sh"
    validateBackupRestoreConfiguration
fi
if [[ "${CONFIG_INIT_DOCKER_COMPOSE_START}" == true ]]; then
    # Validate the Compose path before the mandatory system update. The file
    # and Docker daemon are checked immediately before phase-two startup.
    # shellcheck source=scripts/docker_compose_start.sh
    . "${SCRIPT_D}/scripts/docker_compose_start.sh"
    validateDockerComposeConfiguration
fi

if [[ "${check_config}" == true ]]; then
    printf 'init configuration is valid\n'
    exit 0
fi

checkSU
# isNormalUser is a predicate whose status is intentionally handled here.
# shellcheck disable=SC2310
isNormalUser "${CONFIG_USER}" ||
    die "CONFIG_USER must name an existing non-root user"

user_record="$(getent passwd "${CONFIG_USER}")" ||
    die "cannot resolve user account: ${CONFIG_USER}"
IFS=: read -r _ _ _ _ _ HOME_USER_D _ <<<"${user_record}"
readonly HOME_USER_D
readonly HOME_ROOT_D="/root"

# The package-manager selector is shared by preflight and phase one.
# shellcheck source=scripts/system_update.sh
. "${SCRIPT_D}/scripts/system_update.sh"

runPreflight() {
    local package_manager active_service

    package_manager="$(selected_package_manager)"
    case "${package_manager}" in
        pacman)
            checkCommand pacman
            ;;
        apt)
            checkCommand apt-get
            checkCommand dpkg
            ;;
        *)
            printf 'Unsupported package manager: %s\n' \
                "${package_manager}" >&2
            return 1
            ;;
    esac

    if [[ "${CONFIG_INIT_SSH_HARDENING}" == true ]]; then
        checkCommand sshd
        checkCommand ssh
        checkCommand systemctl

        # A configured user key is installed before hardening. Otherwise the
        # existing account must already have safe public-key access.
        if [[ "${CONFIG_INIT_SSH_KEYS_ADD}" != true ||
            -z "${CONFIG_SSH_KEY_USER:-}" ]]; then
            validateSSHUserAccess "${HOME_USER_D}" "${CONFIG_USER}"
        fi
        # activeSSHService is a predicate whose status is handled here.
        # shellcheck disable=SC2310
        active_service="$(activeSSHService)" || {
            printf 'OpenSSH must be active before hardening\n' >&2
            return 1
        }
        printf 'OpenSSH preflight passed through %s\n' "${active_service}"
    fi

    printf 'init preflight passed for %s using %s\n' \
        "${CONFIG_USER}" "${package_manager}"
}

if [[ "${preflight}" == true ]]; then
    runPreflight
    exit 0
fi

checkCommand flock
exec 9>"${LOCK_F}"
flock -n 9 || die "another provisioning process is already running"

read_boot_id() {
    local boot_id

    [[ -f "${BOOT_ID_F}" && -r "${BOOT_ID_F}" ]] ||
        die "boot ID file is not readable: ${BOOT_ID_F}"
    boot_id="$(<"${BOOT_ID_F}")"
    [[ "${boot_id}" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
        die "invalid boot ID in ${BOOT_ID_F}"
    printf '%s\n' "${boot_id}"
}

read_phase_state() {
    local stored_boot_id

    [[ -f "${STATE_F}" && -r "${STATE_F}" ]] ||
        die "phase state is not readable: ${STATE_F}"
    stored_boot_id="$(<"${STATE_F}")"
    [[ "${stored_boot_id}" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
        die "invalid phase state in ${STATE_F}; remove it after inspection"
    printf '%s\n' "${stored_boot_id}"
}

write_phase_state() {
    local state_boot_id="$1"
    local state_dir="${STATE_F%/*}"

    [[ -n "${state_dir}" ]] || state_dir="/"
    install -d -m 0700 -- "${state_dir}"
    printf '%s\n' "${state_boot_id}" >"${STATE_F}"
    chmod 0600 -- "${STATE_F}"
}

run_phase_one() {
    printf '\nProvisioning phase 1: update and pre-reboot configuration\n'

    # The complete operating-system update must precede every other host
    # configuration change. Any configured official packages are installed as
    # part of this package-management step.
    updateSystem

    if [[ "${CONFIG_INIT_PACKAGE_CLEANUP}" == true ]]; then
        # shellcheck source=scripts/package_cleanup.sh
        . "${SCRIPT_D}/scripts/package_cleanup.sh"
        cleanupPackages
    fi
    # Package installation/removal can create pacnew, pacsave or dpkg
    # inconsistencies, so enforce the package-state gate before configuration.
    checkPackageConfiguration

    if [[ "${CONFIG_INIT_RFKILL}" == true ]]; then
        blockRf
    fi
    if [[ "${CONFIG_INIT_JOURNAL_LIMIT}" == true ]]; then
        limitJournal
    fi
    if [[ "${CONFIG_INIT_MEMORY_CONFIGURE}" == true ]]; then
        configureMemory
    fi
    if [[ "${CONFIG_INIT_PACMAN_ENABLE_COLORS}" == true ]]; then
        # shellcheck source=scripts/pacman_colors.sh
        . "${SCRIPT_D}/scripts/pacman_colors.sh"
        setPacmanColors
    fi
    if [[ "${CONFIG_INIT_RPI_EEPROM_UPDATE}" == true ]]; then
        configureRpiEeprom
    fi
    if [[ "${CONFIG_INIT_RPI_BOOT_CONFIGURE}" == true ]]; then
        configureRpiBoot
    fi
    if [[ "${CONFIG_INIT_USER_ADD_TO_GROUPS}" == true ]]; then
        addUserToGroups
    fi
    if [[ "${CONFIG_INIT_USER_SUDO_WITHOUT_PWD}" == true ]]; then
        # shellcheck source=scripts/user_passwordless_sudo.sh
        . "${SCRIPT_D}/scripts/user_passwordless_sudo.sh"
        enablePasswordlessSudo
    fi
    if [[ "${CONFIG_INIT_SHELL_CONFIGURE}" == true ]]; then
        # shellcheck source=scripts/shell_environment.sh
        . "${SCRIPT_D}/scripts/shell_environment.sh"
        configureShellEnvironment
    fi
    if [[ "${CONFIG_INIT_NANO_CONFIGURE}" == true ]]; then
        # shellcheck source=scripts/nano_syntax_highlighting.sh
        . "${SCRIPT_D}/scripts/nano_syntax_highlighting.sh"
        configureNano
    fi
    if [[ "${CONFIG_INIT_NETWORK_CONFIGURE}" == true ]]; then
        configureNetwork
    fi
    if [[ "${CONFIG_INIT_FSTRIM_ENABLE}" == true ]]; then
        configureFstrim
    fi
    if [[ "${CONFIG_INIT_NTP_CUSTOMIZATION}" == true ]]; then
        customNtp
    fi

    if [[ "${CONFIG_INIT_SSH_KEYS_ADD}" == true ]]; then
        addSSHKeys
    fi
    if [[ "${CONFIG_INIT_SSH_HOSTS_ADD}" == true ]]; then
        addSSHHosts
    fi
    if [[ "${CONFIG_INIT_SSH_HARDENING}" == true ]]; then
        hardenSSH
    fi

    if [[ "${CONFIG_INIT_SRV_BT_ENABLE}" == true ]]; then
        enableService "bluetooth.service" true
    fi
    if [[ "${CONFIG_INIT_DOCKER_DAEMON_CONFIGURE}" == true ]]; then
        configureDockerDaemon
    fi
    if [[ "${CONFIG_INIT_SRV_DOCKER_ENABLE}" == true ]]; then
        # Docker starts during the required reboot. Phase two can then verify
        # and use the daemon after user group membership is active.
        enableService "docker.service" false
    fi
    if [[ "${CONFIG_INIT_SYSTEMD_RESOLVED_CONFIGURE}" == true ]]; then
        configureSystemdResolved
    fi
}

run_phase_two() {
    printf '\nProvisioning phase 2: post-reboot operations\n'

    if [[ "${CONFIG_INIT_DOCKER_LOGIN}" == true ]]; then
        dockerLogin
    fi
    if [[ "${CONFIG_INIT_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE}" == true ]]; then
        createCustomDockerBridgeNetwork
    fi
    if [[ "${CONFIG_INIT_BACKUP_RESTORE}" == true ]]; then
        restoreBackup
    fi
    if [[ "${CONFIG_INIT_DOCKER_COMPOSE_START}" == true ]]; then
        startDockerCompose
    fi
}

current_boot_id="$(read_boot_id)"
readonly current_boot_id

if [[ -e "${STATE_F}" ]]; then
    phase_one_boot_id="$(read_phase_state)"
    readonly phase_one_boot_id
    if [[ "${phase_one_boot_id}" == "${current_boot_id}" ]]; then
        die "phase 1 is complete; reboot before running init again"
    fi

    run_phase_two
    rm -f -- "${STATE_F}"
    printf '\nProvisioning completed successfully\n'
else
    run_phase_one
    write_phase_state "${current_boot_id}"
    printf '\nPhase 1 completed successfully\n'
    printf 'Reboot the system, then run the same provisioner again for phase 2\n'
fi
