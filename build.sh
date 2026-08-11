#!/usr/bin/env bash

# Build one private, pasteable provisioning script from src/init.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SOURCE_DIR="${SCRIPT_DIR}/src/init"
readonly BOOTSTRAP_FILE="${SCRIPT_DIR}/src/bootstrap.sh"
readonly RUNNER_DELIMITER="__LINUX_INIT_RUNNER__"
readonly PAYLOAD_DELIMITER="__LINUX_INIT_PAYLOAD__"

config_file="${LINUX_INIT_CONFIG:-${SOURCE_DIR}/init.env}"
output_file="${LINUX_INIT_OUTPUT:-${SCRIPT_DIR}/build/linux-init.sh}"

usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--config FILE] [--output FILE]

Build one text-only provisioning script containing src/init and a private
configuration file. The result can be executed, piped to Bash or pasted as one
block into an interactive Bash session.

Options:
  -c, --config FILE  Configuration to install as init.env
                     (default: src/init/init.env or LINUX_INIT_CONFIG)
  -o, --output FILE  Generated script
                     (default: build/linux-init.sh or LINUX_INIT_OUTPUT)
  -h, --help         Show this help

Deploy by executing FILE, or print FILE and paste the complete text block into
an interactive Bash session. With no arguments, preflight runs automatically
before provisioning.

Quick start:
  cp src/init/init.env.example src/init/init.env
  chmod 0600 src/init/init.env
  nano src/init/init.env
  ./build.sh

The generated file contains the private configuration. Keep it private and
paste it only into a trusted target. See README.md for the complete two-phase
deployment procedure.
EOF
}

die() {
    printf 'build: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v -- "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while (($# > 0)); do
    case "$1" in
        -c | --config)
            (($# >= 2)) || die "$1 requires a file"
            config_file=$2
            shift 2
            ;;
        -o | --output)
            (($# >= 2)) || die "$1 requires a file"
            output_file=$2
            shift 2
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

for command_name in base64 bash cat chmod cp find grep mkdir mktemp mv \
    realpath rm sha256sum tar; do
    require_command "${command_name}"
done

[[ -r "${SOURCE_DIR}/init.sh" ]] ||
    die "provisioner not found: ${SOURCE_DIR}/init.sh"
[[ -r "${BOOTSTRAP_FILE}" ]] ||
    die "bootstrap not found: ${BOOTSTRAP_FILE}"

config_path="$(realpath -e -- "${config_file}" 2>/dev/null)" ||
    die "configuration file does not exist: ${config_file}"
readonly config_path
[[ -f "${config_path}" && -r "${config_path}" ]] ||
    die "configuration file is not readable: ${config_path}"

output_path="$(realpath -m -- "${output_file}")"
source_path="$(realpath -e -- "${SOURCE_DIR}")"
readonly output_path source_path
if [[ "${output_path}" == "${source_path}" ||
    "${output_path}" == "${source_path}/"* ]]; then
    die "output must be outside ${source_path}"
fi
[[ ! -d "${output_path}" ]] || die "output is a directory: ${output_path}"

# Reuse the provisioner's own validation so build-time and run-time checks
# cannot drift apart.
if ! INIT_ENV_FILE="${config_path}" \
    bash "${SOURCE_DIR}/init.sh" --check-config >/dev/null; then
    die "configuration validation failed: ${config_path}"
fi

output_dir="${output_path%/*}"
output_name="${output_path##*/}"
[[ -n "${output_dir}" ]] || output_dir=/
mkdir -p -- "${output_dir}"

work_dir="$(mktemp -d -- "${TMPDIR:-/tmp}/linux-init-build.XXXXXXXXXX")"
temporary_output=""

cleanup() {
    rm -rf -- "${work_dir}"
    [[ -z "${temporary_output}" ]] || rm -f -- "${temporary_output}"
}
trap cleanup EXIT

temporary_output="$(mktemp -- "${output_dir}/.${output_name}.XXXXXXXXXX")"
readonly work_dir temporary_output

stage_dir="${work_dir}/payload"
payload_archive="${work_dir}/payload.tar.gz"
mkdir -p -- "${stage_dir}"
cp -a -- "${SOURCE_DIR}/." "${stage_dir}/"

# Never include an arbitrary ignored init.env left in the source tree. Only the
# configuration selected above is allowed into the deployment artifact.
rm -f -- "${stage_dir}/init.env"
cp -- "${config_path}" "${stage_dir}/init.env"
chmod 0600 "${stage_dir}/init.env"

# The archive is built only from regular files and directories. Rejecting
# links and special files keeps extraction independent from tar implementation
# details and prevents a payload from escaping its temporary directory.
unsafe_path="$(find "${stage_dir}" -mindepth 1 \
    ! -type f ! -type d -print -quit)"
[[ -z "${unsafe_path}" ]] ||
    die "unsupported payload file type: ${unsafe_path}"
payload_path_list="${work_dir}/payload.paths"
find "${stage_dir}" -mindepth 1 -print0 >"${payload_path_list}"
while IFS= read -r -d '' payload_path; do
    [[ "${payload_path}" != *[$'\r\n']* ]] ||
        die "payload paths must not contain line breaks"
done <"${payload_path_list}"
grep -Fxq -- "${RUNNER_DELIMITER}" "${BOOTSTRAP_FILE}" &&
    die "runner delimiter collides with bootstrap content"
grep -Fxq -- "${PAYLOAD_DELIMITER}" "${BOOTSTRAP_FILE}" &&
    die "payload delimiter collides with bootstrap content"

TAR_OPTIONS="" GZIP="" tar -czf "${payload_archive}" -C "${stage_dir}" .
payload_checksum="$(sha256sum -- "${payload_archive}")"
payload_checksum="${payload_checksum%% *}"
[[ "${payload_checksum}" =~ ^[[:xdigit:]]{64}$ ]] ||
    die "cannot calculate payload checksum"

# The outer subshell makes paste safe: Bash reads the complete compound command
# and both heredocs before starting the child process. The Base64 body is pure
# text, while the checksum detects truncation or clipboard corruption before
# tar sees any data.
{
    cat <<'EOF'
#!/usr/bin/env bash

# Private linux-scripts deployment artifact.
# Execute this file or paste its complete contents into an interactive Bash.
# The embedded configuration is sensitive even though the payload is Base64.
_linux_init_history_was_enabled=false
[[ -o history ]] && _linux_init_history_was_enabled=true
set +o history
(
EOF
    printf '    BASH_ENV=/dev/null bash --noprofile --norc -s -- "$@" <<%s\n' \
        "'${RUNNER_DELIMITER}'"
    cat -- "${BOOTSTRAP_FILE}"
    printf '\nlinux_init_main %q "$@" <<%s\n' \
        "${payload_checksum}" "'${PAYLOAD_DELIMITER}'"
    base64 -- "${payload_archive}"
    printf '%s\n%s\n' "${PAYLOAD_DELIMITER}" "${RUNNER_DELIMITER}"
    cat <<'EOF'
)
_linux_init_status=$?
[[ "${_linux_init_history_was_enabled}" != true ]] || set -o history
if ((_linux_init_status == 0)); then
    unset _linux_init_history_was_enabled _linux_init_status
    true
else
    unset _linux_init_history_was_enabled _linux_init_status
    false
fi
EOF
} >"${temporary_output}"

if LC_ALL=C grep -q $'[^\t\r -~]' "${temporary_output}"; then
    die "generated artifact is not plain text"
fi
chmod 0700 "${temporary_output}"
mv -f -- "${temporary_output}" "${output_path}"

printf 'Built private deployment artifact: %s\n' "${output_path}"
printf 'Execute: %q\n' "${output_path}"
printf 'Copy/paste: cat -- %q\n' "${output_path}"
