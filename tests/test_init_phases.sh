#!/usr/bin/env bash

# Exercise the two-phase state machine with fake package-manager commands.
# No host configuration or real package operation is performed.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly INIT_SCRIPT="${REPO_ROOT}/src/init/init.sh"

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'sudo rm -rf -- "${TEST_TMP}"' EXIT

if ((EUID != 0)) && ! sudo -n true >/dev/null 2>&1; then
    printf 'init phase tests skipped: passwordless sudo is unavailable\n'
    exit 0
fi

fake_bin="${TEST_TMP}/bin"
config_file="${TEST_TMP}/init.env"
state_file="${TEST_TMP}/state/init.state"
boot_id_file="${TEST_TMP}/boot_id"
lock_file="${TEST_TMP}/init.lock"
call_log="${TEST_TMP}/calls.log"
mkdir -p -- "${fake_bin}"
chmod 0755 -- "${TEST_TMP}" "${fake_bin}"
touch "${call_log}"
chmod 0666 -- "${call_log}"

cp -- "${REPO_ROOT}/src/init/init.env.example" "${config_file}"
sed -i \
    -e 's/^CONFIG_USER=.*/CONFIG_USER="nobody"/' \
    -e 's/^CONFIG_PACKAGE_MANAGER=.*/CONFIG_PACKAGE_MANAGER="pacman"/' \
    -e 's/^CONFIG_PACMAN_PACKAGES=.*/CONFIG_PACMAN_PACKAGES="git, htop"/' \
    -e 's/^CONFIG_APT_PACKAGES=.*/CONFIG_APT_PACKAGES="curl, jq"/' \
    -e 's/^CONFIG_INIT_PACKAGE_CLEANUP=.*/CONFIG_INIT_PACKAGE_CLEANUP=true/' \
    "${config_file}"
chmod 0600 -- "${config_file}"

pacman_file="${fake_bin}/pacman"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "pacman %%s\\n" "$*" >>"%s"\n' "${call_log}"
    printf '%s\n' 'if [[ "$*" == "-Qtdq" ]]; then printf "fake-orphan\n"; fi'
} >"${pacman_file}"
chmod 0755 -- "${pacman_file}"

yay_file="${fake_bin}/yay"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "yay %%s\\n" "$*" >>"%s"\n' "${call_log}"
} >"${yay_file}"
chmod 0755 -- "${yay_file}"

paccache_file="${fake_bin}/paccache"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "paccache %%s\\n" "$*" >>"%s"\n' "${call_log}"
} >"${paccache_file}"
chmod 0755 -- "${paccache_file}"

pacdiff_file="${fake_bin}/pacdiff"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf "printf \"%%s\" \"\${FAKE_PACDIFF_OUTPUT:-}\"\n"
} >"${pacdiff_file}"
chmod 0755 -- "${pacdiff_file}"

apt_get_file="${fake_bin}/apt-get"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "apt-get %%s\\n" "$*" >>"%s"\n' "${call_log}"
} >"${apt_get_file}"
chmod 0755 -- "${apt_get_file}"

dpkg_file="${fake_bin}/dpkg"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "dpkg %%s\\n" "$*" >>"%s"\n' "${call_log}"
    printf "[[ \"\$*\" == \"--audit\" ]] && printf \"%%s\" \"\${FAKE_DPKG_AUDIT_OUTPUT:-}\"\n"
} >"${dpkg_file}"
chmod 0755 -- "${dpkg_file}"

run_init() {
    sudo env \
        PATH="${fake_bin}:${PATH}" \
        INIT_BOOT_ID_FILE="${boot_id_file}" \
        INIT_LOCK_FILE="${lock_file}" \
        INIT_STATE_FILE="${state_file}" \
        FAKE_PACDIFF_OUTPUT="${FAKE_PACDIFF_OUTPUT:-}" \
        FAKE_DPKG_AUDIT_OUTPUT="${FAKE_DPKG_AUDIT_OUTPUT:-}" \
        "${INIT_SCRIPT}" --config "${config_file}" "$@"
}

boot_one="11111111-1111-4111-8111-111111111111"
boot_two="22222222-2222-4222-8222-222222222222"

# Preflight validates prerequisites without touching phase state or packages.
run_init --preflight |
    grep -Fx 'init preflight passed for nobody using pacman' >/dev/null
sudo test ! -e "${state_file}"
sudo test ! -e "${lock_file}"
[[ ! -s "${call_log}" ]]

# Identity creation belongs to the OS installer; preflight must reject a
# configured account that is not already present on the target host.
missing_user_config="${TEST_TMP}/missing-user.env"
cp -- "${config_file}" "${missing_user_config}"
sed -i 's/^CONFIG_USER=.*/CONFIG_USER="linux-scripts-user-that-does-not-exist"/' \
    "${missing_user_config}"
set +e
sudo env \
    PATH="${fake_bin}:${PATH}" \
    INIT_BOOT_ID_FILE="${boot_id_file}" \
    INIT_LOCK_FILE="${lock_file}" \
    INIT_STATE_FILE="${state_file}" \
    "${INIT_SCRIPT}" --config "${missing_user_config}" --preflight \
    >/dev/null 2>&1
missing_user_status=$?
set -e
if ((missing_user_status == 0)); then
    printf 'init preflight accepted a missing CONFIG_USER account\n' >&2
    exit 1
fi
[[ ! -s "${call_log}" ]]

printf '%s\n' "${boot_one}" >"${boot_id_file}"

run_init >/dev/null
sudo test -f "${state_file}"
sudo grep -Fx "${boot_one}" "${state_file}" >/dev/null
grep -Fx 'pacman -Syu --needed sudo pacman-contrib git htop' \
    "${call_log}" >/dev/null
grep -Fx 'yay -Syu --aur' "${call_log}" >/dev/null
grep -Fx 'pacman -Qtdq' "${call_log}" >/dev/null
grep -Fx 'pacman -Rns --noconfirm fake-orphan' "${call_log}" >/dev/null
grep -Fx 'paccache -rk0' "${call_log}" >/dev/null
grep -Fx 'yay -Sc --aur --noconfirm' "${call_log}" >/dev/null

# A second invocation in the same boot must not update or configure again.
: >"${call_log}"
set +e
run_init >/dev/null 2>&1
run_status=$?
set -e
if ((run_status == 0)); then
    printf 'init accepted phase 2 without a reboot\n' >&2
    exit 1
fi
[[ ! -s "${call_log}" ]]

# A different boot ID unlocks phase two and successful completion clears state.
printf '%s\n' "${boot_two}" >"${boot_id_file}"
run_init >/dev/null
sudo test ! -e "${state_file}"
[[ ! -s "${call_log}" ]]

# Unresolved Pacman configuration files must stop before state is recorded.
set +e
FAKE_PACDIFF_OUTPUT="/etc/example.conf.pacnew" run_init >/dev/null 2>&1
run_status=$?
set -e
if ((run_status == 0)); then
    printf 'init accepted an unresolved pacnew file\n' >&2
    exit 1
fi
sudo test ! -e "${state_file}"

# Exercise the APT update/audit path as well.
: >"${call_log}"
sed -i 's/^CONFIG_PACKAGE_MANAGER=.*/CONFIG_PACKAGE_MANAGER="apt"/' \
    "${config_file}"
run_init >/dev/null
grep -Fx 'apt-get update' "${call_log}" >/dev/null
grep -Fx 'apt-get dist-upgrade' "${call_log}" >/dev/null
grep -Fx 'apt-get install -- curl jq' "${call_log}" >/dev/null
grep -Fx 'apt-get --yes autoremove' "${call_log}" >/dev/null
grep -Fx 'apt-get clean' "${call_log}" >/dev/null
grep -Fx 'apt-get check' "${call_log}" >/dev/null
grep -Fx 'dpkg --audit' "${call_log}" >/dev/null
sudo test -f "${state_file}"

printf '%s\n' "${boot_one}" >"${boot_id_file}"
run_init >/dev/null
sudo test ! -e "${state_file}"

printf 'init phase tests passed\n'
