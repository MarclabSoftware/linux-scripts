#!/usr/bin/env bash

# Replace public Unbound root hints and recover the previous file if reload fails.
# Usage: unbound_update_root_hints.sh HINTS_FILE CONFIG_FILE CONTROL_SOCKET
set -Eeuo pipefail

if [[ "${BASH_SOURCE[0]}" == "$0" && ("${1:-}" == --help || "${1:-}" == -h) ]]; then
    cat <<'HELP'
Usage: unbound_update_root_hints.sh HINTS_FILE CONFIG_FILE CONTROL_SOCKET
Update the public root hints, validate Unbound, then reload it. All paths must
be absolute. Failed validation/reload restores the previous hints; a failed
recovery retains both files in the reported private transaction directory.
Requires curl, unbound-checkconf, unbound-control and GNU coreutils.
Install as described in systemd/README.md; this command updates the live resolver.
HELP
    exit 0
fi
umask 077

die() {
    printf 'unbound root hints: %s\n' "$*" >&2
    exit 1
}
(($# == 3)) || die "expected HINTS_FILE CONFIG_FILE CONTROL_SOCKET"
hints_file="$1" config_file="$2" control_socket="$3"
for path in "${hints_file}" "${config_file}" "${control_socket}"; do
    [[ "${path}" == /* ]] || die "paths must be absolute"
done
[[ ! -L "${hints_file}" && (! -e "${hints_file}" || -f "${hints_file}") ]] || die "hints must be a regular file"

work_dir="$(mktemp -d -- "${hints_file%/*}/.root-hints.XXXXXX")"
published=false committed=false had_previous=false

finish() {
    local status=$? recovery_failed=0
    trap - EXIT HUP INT TERM
    if [[ "${published}" == true && "${committed}" != true ]]; then
        if [[ "${had_previous}" == true ]]; then
            ln -- "${work_dir}/previous" "${work_dir}/restore" &&
                mv -fT -- "${work_dir}/restore" "${hints_file}" || recovery_failed=1
        else
            rm -f -- "${hints_file}" || recovery_failed=1
        fi
        if ((recovery_failed == 0)); then
            unbound-checkconf "${config_file}" &&
                unbound-control -c "${config_file}" -s "${control_socket}" reload || recovery_failed=1
        fi
        if ((recovery_failed != 0)); then
            printf 'unbound root hints: recovery failed; previous and candidate files retained in %s\n' "${work_dir}" >&2
            exit 1
        fi
        printf 'unbound root hints: previous file and running configuration restored\n' >&2
    fi
    rm -rf -- "${work_dir}" || status=1
    exit "${status}"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 60 --output "${work_dir}/candidate" \
    https://www.internic.net/domain/named.cache
[[ -s "${work_dir}/candidate" ]] || die "downloaded root hints are empty"
grep -Eq '^[.][[:space:]]+[0-9]+[[:space:]]+(IN[[:space:]]+)?NS[[:space:]]+' "${work_dir}/candidate" ||
    die "downloaded file contains no root NS records"
if [[ -f "${hints_file}" ]]; then
    if cmp -s -- "${hints_file}" "${work_dir}/candidate"; then
        printf 'Unbound root hints are unchanged\n'
        exit 0
    fi
    # Hold the old inode and its ownership; never modify this backup in place.
    ln -- "${hints_file}" "${work_dir}/previous"
    had_previous=true
fi
chmod 0644 -- "${work_dir}/candidate"
cp --preserve=mode,timestamps -- "${work_dir}/candidate" "${work_dir}/publish"
published=true
mv -fT -- "${work_dir}/publish" "${hints_file}"
unbound-checkconf "${config_file}"
unbound-control -c "${config_file}" -s "${control_socket}" reload
committed=true
printf 'Unbound root hints updated and reloaded\n'
