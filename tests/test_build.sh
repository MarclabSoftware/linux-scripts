#!/usr/bin/env bash

# Exercise the text-only build artifact without provisioning the host.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly PAYLOAD_DELIMITER="__LINUX_INIT_PAYLOAD__"
readonly RUNNER_DELIMITER="__LINUX_INIT_RUNNER__"

test_dir="$(mktemp -d)"
trap 'rm -rf -- "${test_dir}"' EXIT

assert_directory_empty() {
    local first_entry

    first_entry="$(find "$1" -mindepth 1 -print -quit)" || return
    [[ -z "${first_entry}" ]]
}

config_file="${test_dir}/private config/init.env"
artifact="${test_dir}/output with spaces/linux-init.sh"
extract_dir="${test_dir}/extracted"
runtime_dir="${test_dir}/runtime"
mkdir -p -- "${config_file%/*}" "${artifact%/*}" \
    "${extract_dir}" "${runtime_dir}"
cp -- "${REPO_ROOT}/src/init/init.env.example" "${config_file}"
chmod 0600 "${config_file}"
printf 'keep\n' >"${artifact%/*}/sentinel"

TAR_OPTIONS="--linux-init-invalid-option" \
    GZIP="--linux-init-invalid-option" \
    "${REPO_ROOT}/build.sh" \
    --config "${config_file}" \
    --output "${artifact}" >/dev/null

[[ -x "${artifact}" ]]
artifact_mode="$(stat -c '%a' "${artifact}")"
[[ "${artifact_mode}" == "700" ]]
[[ -f "${artifact%/*}/sentinel" ]]

# The artifact must be safe to execute as a file and to feed to Bash exactly
# as an interactive copy/paste block would be.
TAR_OPTIONS="--linux-init-invalid-option" \
    GZIP="--linux-init-invalid-option" \
    TMPDIR="${runtime_dir}" "${artifact}" --check-config >/dev/null
TMPDIR="${runtime_dir}" bash -s -- --check-config \
    <"${artifact}" >/dev/null
TMPDIR="${runtime_dir}" bash -c "
    set -o history
    source \"\$1\" --check-config
    [[ -o history ]]
    ! declare -p _linux_init_history_was_enabled _linux_init_status \
        >/dev/null 2>&1
" _ "${artifact}" >/dev/null
assert_directory_empty "${runtime_dir}"

if LC_ALL=C grep -q $'[^\t\r -~]' "${artifact}"; then
    printf 'generated artifact contains non-text bytes\n' >&2
    exit 1
fi
if grep -qF 'CONFIG_USER=' "${artifact}"; then
    printf 'private configuration leaked outside the encoded payload\n' >&2
    exit 1
fi
payload_delimiter_count="$(grep -cxF \
    "${PAYLOAD_DELIMITER}" "${artifact}")"
runner_delimiter_count="$(grep -cxF \
    "${RUNNER_DELIMITER}" "${artifact}")"
[[ "${payload_delimiter_count}" == 1 ]]
[[ "${runner_delimiter_count}" == 1 ]]

# Decode the payload independently and verify both its checksum and contents.
encoded_payload="${test_dir}/payload.base64"
payload_archive="${test_dir}/payload.tar.gz"
awk -v delimiter="${PAYLOAD_DELIMITER}" \
    -v start_marker="<<'${PAYLOAD_DELIMITER}'" '
    index($0, start_marker) { copying = 1; next }
    $0 == delimiter { exit }
    copying { print }
' "${artifact}" >"${encoded_payload}"
[[ -s "${encoded_payload}" ]]
base64 --decode "${encoded_payload}" >"${payload_archive}"
expected_checksum="$(awk '$1 == "linux_init_main" { print $2; exit }' \
    "${artifact}")"
actual_checksum="$(sha256sum -- "${payload_archive}")"
actual_checksum="${actual_checksum%% *}"
[[ "${actual_checksum}" == "${expected_checksum}" ]]
tar -xzf "${payload_archive}" -C "${extract_dir}"

cmp -- "${config_file}" "${extract_dir}/init.env"
config_mode="$(stat -c '%a' "${extract_dir}/init.env")"
[[ "${config_mode}" == "600" ]]
for required_file in \
    init.sh \
    scripts/utils.sh \
    scripts/system_update.sh \
    scripts/package_cleanup.sh \
    scripts/memory.sh \
    scripts/network.sh \
    scripts/fstrim.sh \
    scripts/rpi_eeprom.sh \
    scripts/rpi_boot_config.sh \
    scripts/systemd_resolved.sh \
    scripts/ssh_add_keys.sh \
    scripts/ssh_add_hosts.sh \
    scripts/ssh_hardening.sh; do
    [[ -f "${extract_dir}/${required_file}" ]]
done
[[ ! -e "${extract_dir}/scripts/dns.sh" ]]
[[ ! -e "${extract_dir}/scripts/ssh_prepare.sh" ]]

# Changing or dropping one Base64 line must fail before init.sh is reached.
for damage_mode in corrupt truncate; do
    damaged_artifact="${test_dir}/${damage_mode}.sh"
    awk -v delimiter="${PAYLOAD_DELIMITER}" \
        -v start_marker="<<'${PAYLOAD_DELIMITER}'" \
        -v mode="${damage_mode}" '
        index($0, start_marker) { payload = 1; print; next }
        payload && $0 == delimiter { payload = 0; print; next }
        payload && !changed {
            changed = 1
            if (mode == "truncate") {
                next
            }
            replacement = substr($0, 1, 1) == "A" ? "B" : "A"
            $0 = replacement substr($0, 2)
        }
        { print }
        END { if (!changed) exit 1 }
    ' "${artifact}" >"${damaged_artifact}"
    if TMPDIR="${runtime_dir}" bash "${damaged_artifact}" \
        --check-config >/dev/null 2>&1; then
        printf 'bootstrap accepted a %s payload\n' "${damage_mode}" >&2
        exit 1
    fi
    assert_directory_empty "${runtime_dir}"
done

# The no-argument path must run preflight first and start provisioning only
# after it succeeds. A tiny trusted payload and a mock runner keep this local.
dispatch_dir="${test_dir}/dispatch"
dispatch_payload="${dispatch_dir}/payload"
dispatch_archive="${dispatch_dir}/payload.tar.gz"
dispatch_encoded="${dispatch_dir}/payload.base64"
dispatch_log="${dispatch_dir}/calls.log"
mkdir -p -- "${dispatch_payload}"
printf '#!/usr/bin/env bash\n' >"${dispatch_payload}/init.sh"
printf 'CONFIG_USER="test"\n' >"${dispatch_payload}/init.env"
tar -czf "${dispatch_archive}" -C "${dispatch_payload}" .
base64 -- "${dispatch_archive}" >"${dispatch_encoded}"
dispatch_checksum="$(sha256sum -- "${dispatch_archive}")"
dispatch_checksum="${dispatch_checksum%% *}"
(
    # shellcheck source=src/bootstrap.sh
    . "${REPO_ROOT}/src/bootstrap.sh"
    linux_init_run_provisioner() {
        local argument separator=""

        for argument in "$@"; do
            printf '%s%s' "${separator}" "${argument}" >>"${dispatch_log}"
            separator=" "
        done
        printf '\n' >>"${dispatch_log}"
    }
    TMPDIR="${runtime_dir}" linux_init_main "${dispatch_checksum}" \
        <"${dispatch_encoded}" >/dev/null
)
dispatch_call_count="$(wc -l <"${dispatch_log}")"
[[ "${dispatch_call_count}" == 2 ]]
sed -n '1p' "${dispatch_log}" | grep -qE '/init\.sh --preflight$'
sed -n '2p' "${dispatch_log}" | grep -qE '/init\.sh$'
assert_directory_empty "${runtime_dir}"

# A failing preflight must prevent the provisioning invocation.
: >"${dispatch_log}"
set +e
(
    # shellcheck source=src/bootstrap.sh
    . "${REPO_ROOT}/src/bootstrap.sh"
    linux_init_run_provisioner() {
        local argument separator=""

        for argument in "$@"; do
            printf '%s%s' "${separator}" "${argument}" >>"${dispatch_log}"
            separator=" "
        done
        printf '\n' >>"${dispatch_log}"
        [[ "${2:-}" != "--preflight" ]]
    }
    TMPDIR="${runtime_dir}" linux_init_main "${dispatch_checksum}" \
        <"${dispatch_encoded}" >/dev/null 2>&1
)
failed_preflight_status=$?
set -e
if ((failed_preflight_status == 0)); then
    printf 'bootstrap continued after a failed preflight\n' >&2
    exit 1
fi
dispatch_call_count="$(wc -l <"${dispatch_log}")"
[[ "${dispatch_call_count}" == 1 ]]
grep -qE '/init\.sh --preflight$' "${dispatch_log}"
assert_directory_empty "${runtime_dir}"

# Even a correctly checksummed archive must not contain traversal paths.
malicious_dir="${test_dir}/malicious"
malicious_archive="${malicious_dir}/payload.tar.gz"
malicious_encoded="${malicious_dir}/payload.base64"
mkdir -p -- "${malicious_dir}/source"
printf 'do not extract\n' >"${malicious_dir}/source/file"
tar -czf "${malicious_archive}" -C "${malicious_dir}/source" \
    --transform='s|^\./|../|' .
base64 -- "${malicious_archive}" >"${malicious_encoded}"
malicious_checksum="$(sha256sum -- "${malicious_archive}")"
malicious_checksum="${malicious_checksum%% *}"
set +e
(
    # shellcheck source=src/bootstrap.sh
    . "${REPO_ROOT}/src/bootstrap.sh"
    linux_init_run_provisioner() {
        return 0
    }
    TMPDIR="${runtime_dir}" linux_init_main "${malicious_checksum}" \
        <"${malicious_encoded}" >/dev/null 2>&1
)
malicious_status=$?
set -e
if ((malicious_status == 0)); then
    printf 'bootstrap accepted an archive traversal path\n' >&2
    exit 1
fi
[[ ! -e "${runtime_dir}/file" ]]
assert_directory_empty "${runtime_dir}"

# A failed rebuild must leave the last valid artifact untouched.
preserved_artifact="${test_dir}/preserved-linux-init.sh"
cp -- "${artifact}" "${preserved_artifact}"
if "${REPO_ROOT}/build.sh" \
    --config "${test_dir}/missing.env" \
    --output "${artifact}" >/dev/null 2>&1; then
    printf 'build accepted a missing configuration file\n' >&2
    exit 1
fi
cmp -- "${preserved_artifact}" "${artifact}"

printf 'build tests passed\n'
