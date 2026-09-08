#!/usr/bin/env bash

# All network/firewall calls are test doubles; clocks advance without sleeping.
# Subshell-local configuration and checked test doubles are intentional.
# shellcheck disable=SC2030,SC2310,SC2329
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
export IP_BLOCKER_ENV_FILE=/nonexistent GEOIP_ENV_FILE=/nonexistent

# Each actual DNS request is bounded; source downloads do not need probe sites.
for script in ip_blocker geo_ip_downloader; do
    (
        # shellcheck disable=SC1090
        source "${REPO_ROOT}/src/scripts/${script}.sh"
        DNS_SERVERS=192.0.2.53
        dig() {
            [[ " $* " == *' +time=2 '* && " $* " == *' +tries=1 '* ]] || exit 94
            [[ "${*: -1}" != A ]] || printf '192.0.2.80\n'
        }
        resolve_opts_str=''
        build_resolve_options_for_url https://fresh.example resolve_opts_str
        [[ "${resolve_opts_str}" == '--resolve fresh.example:443:192.0.2.80' ]]
        DNS_SERVERS=''
        build_resolve_options_for_url https://native-resolver.example resolve_opts_str
        [[ -z "${resolve_opts_str}" ]]
        if declare -F check_connectivity >/dev/null || declare -F try_command >/dev/null; then
            exit 1
        fi
    )
done

# Exactly one retry owner; no final backoff and no whole-provider retries.
for outcome in failed second_attempt; do
    (
        export GEOIP_MAX_DOWNLOAD_RETRIES=3
        # shellcheck source=src/scripts/geo_ip_downloader.sh
        source "${REPO_ROOT}/src/scripts/geo_ip_downloader.sh"
        calls=0 slept=''
        curl() {
            calls=$((calls + 1))
            [[ " $* " == *' --connect-timeout 10 --max-time 30 '* ]]
            [[ "${outcome}" == second_attempt && "${calls}" == 2 ]]
        }
        sleep() { slept+="$1 "; }
        if download_file https://lists.example/test "${TEST_TMP}/partial"; then
            [[ "${outcome}" == second_attempt && "${calls}" == 2 && "${slept}" == '2 ' ]]
        else
            [[ "${outcome}" == failed && "${calls}" == 3 && "${slept}" == '2 4 ' ]]
        fi
    )
done

# Run main with errexit enabled, not as an if-condition that masks failures.
for cache in ready missing; do
    set +e
    (
        export IP_BLOCKER_LIST_DIR="${TEST_TMP}/flow-${cache}"
        export IP_BLOCKER_COUNTRIES=IT
        export IP_BLOCKER_USE_BLOCKLIST=false
        # shellcheck source=src/scripts/ip_blocker.sh
        source "${REPO_ROOT}/src/scripts/ip_blocker.sh"
        setup_temp_dir_and_traps() {
            IP_RANGE_FILE_V4="${TEST_TMP}/ranges-${cache}"
            printf '192.0.2.0/24\n' >"${IP_RANGE_FILE_V4}"
        }
        log_dns_config() { :; }
        check_installed_commands() { :; }
        nft() { :; }
        generate_ip_list() {
            touch "${TEST_TMP}/generated-${cache}"
            [[ "${cache}" == ready ]] || die 'No validated cache'
        }
        apply_rules_nftables() { touch "${TEST_TMP}/applied-${cache}"; }
        main
    ) >"${TEST_TMP}/flow-${cache}.log" 2>&1
    status=$?
    set -e
    [[ -f "${TEST_TMP}/generated-${cache}" ]] || {
        cat "${TEST_TMP}/flow-${cache}.log" >&2
        exit 1
    }
    if [[ "${cache}" == ready ]]; then
        [[ "${status}" == 0 && -f "${TEST_TMP}/applied-${cache}" ]]
    else
        [[ "${status}" != 0 && ! -e "${TEST_TMP}/applied-${cache}" ]]
    fi
done

unit="${REPO_ROOT}/systemd/ip_blocker@.service"
grep -Fxq 'Restart=on-failure' "${unit}"
grep -Fxq 'RestartSec=60s' "${unit}"
grep -Fxq 'StartLimitIntervalSec=0' "${unit}"
grep -Fxq 'After=network.target' "${unit}"
if grep -Eq '^(Wants|After|Requires)=.*(network-online|docker.service)' "${unit}"; then
    exit 1
fi

# Exercise real curl fallback, on loopback only, with unreachable alternatives.
python3 - "${REPO_ROOT}" <<'PY'
import http.server
import pathlib
import shlex
import subprocess
import sys
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_):
        pass


with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://lists.example:{server.server_port}/"
        for script in ("ip_blocker", "geo_ip_downloader"):
            path = pathlib.Path(sys.argv[1]) / "src/scripts" / f"{script}.sh"
            for addresses in (
                "127.0.0.1 127.0.0.2 2001:db8::80",
                "2001:db8::80 127.0.0.2 127.0.0.1",
            ):
                result = subprocess.run(
                    ["bash", "-c", '''
source "$1"
DNS_SERVERS=192.0.2.53
RESOLVED_HOSTS_CACHE[lists.example]="$3"
resolved_options=''
build_resolve_options_for_url "$2" resolved_options
printf '%s' "$resolved_options"
''', "resolve-test", str(path), url, addresses],
                    check=True, capture_output=True, text=True,
                )
                response = subprocess.run(
                    ["curl", "--noproxy", "*", "-fsS", "--connect-timeout", "1",
                     "--max-time", "3", *shlex.split(result.stdout), url],
                    check=True, capture_output=True, timeout=5,
                )
                assert response.stdout == b"ok", (script, addresses)
    finally:
        server.shutdown()
        thread.join()
PY

printf 'Firewall connectivity and retry tests passed\n'
