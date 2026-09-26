# Operational scripts

Run `SCRIPT --help` for its command syntax. Scripts here are executable entry
points, except `media/media_common.sh`, which must remain beside the media
commands that source it. These files are independent of the provisioner.

## Configuration and installation

Copy only the selected script and its required companion files. Scripts normally
load their adjacent `.env`; the header documents the component-specific
`*_ENV_FILE` override. Sidecars are trusted shell code, not a general-purpose
data format. Values assigned by a sidecar can replace exported values; CLI
options override them where supported. `cert_monitor.sh` instead receives its
environment from the caller or its systemd unit. Its CLI takes precedence.

Copy an `.example` to the same name without `.example`, edit the copy and use
mode `0600` for private configuration. Do not replace an existing sidecar during
an upgrade. The account running a script needs read access to its configuration
and write access to its outputs. Scripts run as root must be installed in paths
that untrusted accounts cannot change.

Use `--check-config` where supported. It checks configuration and, for some
components, referenced paths; it does not prove that the remote service,
hardware or eventual operation works. No real sidecar is needed for `--help`.

## Deployment matrix

All Bash commands need the Linux/GNU baseline described in the root README.
The dependencies below name the additional component tools, not every coreutil.
Docker access grants substantial control over the host even without UID 0.

| Script or family | Main additional dependencies | Privilege / files needed |
| --- | --- | --- |
| `cert_monitor.sh` | OpenSSL, inotify-tools; systemd-notify under its unit | Certificate reader and PFX destination writer; `.env` is loaded by the unit |
| `mtls_certificates.sh` | OpenSSL | Normal user; password files and private output directory; one shared client identity |
| `npm_cleaner.sh` | findutils | Certificate tree reader for preview, writer for deletion; `.env` |
| `npmplus_ech_cloudflare.sh` | POSIX shell, curl, jq, OpenSSL, flock | NPMplus ECH hook; API token in an owner-only `.env` |
| `docker_network.sh` | Docker CLI/daemon | Docker access; `.env`; verifies explicitly requested driver, IPv6 and IPAM settings |
| `geo_ip_downloader.sh` | curl, AWK; md5sum for RIPE | List directory writer; optional `.env`; invoked by `ip_blocker.sh` |
| `ip_blocker.sh` | iprange 2.0+ with IPv6/directory/filelist features; native nftables; curl, flock | Root; downloader beside it, firewall `.env` and configured list trees |
| `ethtool_optimizations.sh` | ethtool | Root or appropriate network capability; `.env` |
| `devices.sh` | udevadm | Normal user; no sidecar; reads USB metadata |
| `power_state.sh` | mosquitto_pub with options-file support | Sysfs/options reader and MQTT socket access; `.env` plus private `.conf` |
| `webos_devmode.sh` | OpenSSH client, curl | Normal user; `.env`, SSH key, writable token/known-hosts state directory |
| `ssh_audit.sh` | Git, Python 3 | Normal user; writable user cache; fetches upstream on each audit |
| `update_arch.sh` | pacman, flock; enabled optional tools | Root; `.env` and optional backup `.paths`; package operations change the host |
| `update_debian.sh` | apt-get, flock; enabled optional tools | Root; `.env` and optional backup `.paths`; package operations change the host |
| `cold_backup.sh` | rsync, findmnt, blkid; mount tools for real runs | Root for mounting; `.env`; mounted readable targets for dry run |
| `clone_disk.sh` | rsync, parted, util-linux, ext4/FAT tools | Root; interactive source/destination validation and wipe confirmation |
| `vaultwarden_backup_send.sh` | sqlite3, rsync, tar, OpenSSH, flock | Source data/SSH access; `.env`; receiver installed on the destination |
| `vaultwarden_backup_receive.sh` | tar, sha256sum, sqlite3, rsync, flock; Docker for standby refresh | Restricted SSH account; `vaultwarden_recovery.env` |
| `vaultwarden_restore.sh` | sha256sum, sqlite3, flock; Docker Compose for apply | Snapshot/data access; `vaultwarden_recovery.env`; Docker only for live restore |
| `update_zbdonglee.sh` | curl, Python 3/uv, universal-silabs-flasher; Docker Compose if configured | Serial-device access; `.env`; explicitly confirmed reset when requested |
| `argonone_install.sh`, `pigpiod_install.sh` | Script-specific package/build tools | Supported Raspberry Pi hardware; interactive installation/elevation |
| `media/convert_to_mp4.sh`, `standardize_mp4.sh`, `fix_corrupt_images.sh` | FFmpeg, ffprobe | Normal user with media write access; `media_common.sh` and optional `media_tools.env` |
| `media/archive_source_files.sh` | findutils, realpath | Source/archive write access; same media library/configuration |
| `media/install_static_ffmpeg.sh` | curl, tar, xz, checksum tools | Download/build directory access and install privilege; optional `.env`; x86_64/aarch64 |
| `unbound_update_root_hints.sh` | curl, unbound-checkconf, unbound-control | Root under the supplied service; installed at the libexec path in the systemd guide |

DNS overrides in the firewall/downloader additionally require their documented
resolver tools. Address, interface and provider choices remain administrator
configuration; examples do not infer a host's topology.

## Backups and deletion

Vaultwarden snapshots and pre-update configuration archives are **not encrypted
at rest by these scripts**. SSH encrypts the Vaultwarden transfer. Keep snapshot
directories and their storage access private. PKCS#12 encryption belongs to the
certificate tools and does not change this backup behavior.

The update scripts read one absolute backup path per `.paths` line. Empty lines
and lines starting with `#` are ignored. Prefix an optional path with `?`, for
example `?/etc/example-optional.conf`. Missing required paths or tar/read errors
abort before package updates. Spaces are literal parts of a path; shell quotes,
globs and tar options are not interpreted. Only a complete archive is renamed
from `.part` to its final owner-only `.tar.gz` name.

`cold_backup.sh --dry-run` uses rsync's preview with no mount, unmount, lock,
directory creation or sync. Source and destination filesystems must already be
mounted. Real runs validate the source mount before `--delete`; one failed drive
does not prevent attempting the other. An occupied mount is left attached and
reported as an error. The in-place rsync policy is a mirror operation,
not a snapshot transaction.

`clone_disk.sh` supports ext4 root plus one FAT boot partition with Raspberry Pi
firmware or systemd-boot. It has no unattended or dry-run mode. Swap files are
excluded from copying, retained when valid or recreated on the destination;
swap partitions are not recreated. A live file-level clone is not automatically
application-consistent. Failed unmounts remain visible for operator recovery.

Vaultwarden restore acquires receiver and standby locks, stages beside the real
data directory, and checks container startup and health before committing.
Failed restore attempts recover the previous data and initial running/stopped
state when possible. Failed rollback retains the named transaction directory;
do not remove it until the active data and container state have been verified.
`--verify` does not require Docker or change the live data directory.

## Firewall

### Policy and scope

Native nftables only. `ip_blocker` owns **one inet table** and adds filtering,
not permission to reach host or Docker services. It neither flushes the ruleset
nor edits other tables. Later base-chain drops still apply; keep service/port
access policy in the host firewall, router or OCI rules.

The effective public allowlist is:

```text
((country networks - remote blocks) + manual allows) - manual blocks
```

Private IPv4, ULA/link-local IPv6, loopback, `wg*`, `docker0` and `br-*`
origins bypass GeoIP and SSH meters. WireGuard's inner traffic is already
authenticated; its outer WAN UDP handshake is **not** exempt. Private source
addresses alone are not authentication: maintain anti-spoofing at the perimeter.
Established/related traffic in either direction bypasses GeoIP; changing a list
does not terminate existing sessions. ICMPv6, including extension headers,
bypasses GeoIP for NDP, MLD and path-MTU discovery.

IPv6 GeoIP filtering is opt-in. With it enabled, **every** chosen provider must
supply valid IPv6 lists; Nirsoft is IPv4-only. Without it, IPv6 country downloads
and subtraction are skipped, not implicitly blocked.

New, untrusted SSH traffic has a per-source meter: 10 packets/second, burst 5,
65,536 entries per family, one-minute idle expiry. Allocation failure drops new
untracked sources; established sessions remain usable. GeoIP drop logs are
capped per family at 30/minute (burst 10); SSH logs at 5/minute (burst 5).
Separate unconditional drop rules enforce both policies even when logging is
exhausted. A successful filter reload resets meters and counters.

### Configuration, cache and startup

Run `ip_blocker.sh --check-config` before applying; it validates configuration,
not reachability or the future kernel batch. The firewall sidecar owns countries,
IPv6 and list paths. It passes `-c`, `-6`, `-o` to the downloader, overriding
its optional standalone defaults. Tune download concurrency/retries there only
if needed. `DNS_SERVERS` optionally uses bounded `dig` queries; unresolved
overrides fall back to the system resolver. Downloads contact the configured
sources directly, with bounded retries.

HTTP success alone is insufficient: markup, address-free responses and partial
downloads are rejected. Country data also rejects wrong-family entries and
catch-all prefixes, including noncanonical /0. An unavailable source may reuse
only its exact validated cache, preserving the last-success timestamp. If required
data is still missing, the run fails and **live rules stay unchanged**. With remote
blocking enabled, this also applies to missing blocklists: no silent downgrade
to GeoIP-only. Summaries report fresh/cached GeoIP and blocklist counts and
oldest cache age. The firewall also reports resulting network counts and duration.
There is intentionally no cache-age cutoff: operator-visible stale data is
preferable to silently losing the policy.

GeoIP IPv4 octets are normalized to decimal before publication, including
cached lists and range endpoints. RIPE allocation counts become exact start/end
ranges; iprange then converts them to CIDRs without assuming alignment or a
power-of-two count. RIPE IPv4 cache files containing CIDRs are rejected.
If neither a fresh download nor a valid cache is available, the run fails and
active rules stay intact.

The kernel update is one checked nft transaction. Cache directories use staged
renames and rollback, **not** one atomic multi-directory transaction. If
interrupted during replacement or rollback fails, the named `.ipblocker.*` or
`.geoip.*` directory retains recovery copies. Stop retries and inspect the
active/backup directories before choosing which to restore; do not delete
recovery data blindly. Country data is replaceable, but restoring the previous
cache should be an explicit operator action.

The stable `IP_BLOCKER_LOCK_DIR/lock` uses `flock`; never unlink it while a
run is active. Do not launch the standalone downloader concurrently against the
same output tree. The service does not wait for Docker or network-online;
failed runs retry after 60 seconds. No tables are restored at reboot: router/OCI
restrictions remain important until the first successful run. See the
[unit guide](../../systemd/README.md).

### NAT and flow offload

No NAT is generated here. Docker owns container NAT; a VPN exit can load the
separate `wireguard_nat.nft.example` from its lifecycle hooks. That example
matches the incoming tunnel, outgoing uplink and VPN source prefixes; NAT66 is
limited to ULA sources. Adapt it to the host's actual routing.

Offload requires candidate interfaces (`IP_BLOCKER_FLOWTABLE_INTERFACES`) and
trusted **initiating** interfaces (`IP_BLOCKER_FLOWTABLE_TRUSTED_INTERFACES`).
Admission priority is forward `+10`, after the usual Docker `0` and Fail2ban
`-1` hooks; verify actual priorities on the target. Only established, original-
direction TCP/UDP is eligible. DNAT/published services are never offloaded, so
later bans remain effective. This does not accelerate local services or
WireGuard encryption.

An offloaded trusted flow bypasses later forwarding hooks: exclude traffic
requiring continuous inspection or immediate bans. Both ends and bridge ports
must exist; absent interfaces safely leave the normal path active. Bridge ports
are a snapshot at each run, not a dynamic Docker watcher. Route/interface changes
may require a refresh; do not assume an offload cache follows every topology
change instantly. These limits follow the [kernel flowtable design](https://docs.kernel.org/networking/nf_flowtable.html).

### Install and verify

Install `ip_blocker.sh` and `geo_ip_downloader.sh` in the same directory. Configure
the firewall using [`ip_blocker.env.example`](ip_blocker.env.example), then run
`ip_blocker.sh --check-config`. Preserve host-specific sidecars when replacing
scripts. NAT is configured separately as described above.

Keep an independent recovery connection available when applying the firewall.
After a run, check its exit status and logs, inspect its nftables table and test
new connections and any VPN exit routing. The script manages only its configured
table; other firewall loaders and their rules require separate administration.

Focused tests:

```bash
(
    set -e
    for part in config connectivity recovery safety parser input forwarding; do
        bash "tests/test_firewall_${part}.sh"
    done
    bash tests/test_geoip_lists.sh
    unshare -Urn bash tests/test_firewall_lock.sh
    bash tests/test_systemd_units.sh
)
```

Failure-injection tests exercise caches, retries and rollback. Kernel tests use
disposable network namespaces with synthetic interfaces, not real WireGuard
encryption or production Docker. They check IPv4/IPv6, SSH saturation/expiry,
NAT/source preservation, trusted offload, non-offloaded public bans and foreign
table preservation. Verify actual service behavior on each deployment host,
including after reboot.

## Media behavior

The media commands retain all mapped streams, metadata and chapters. Unsupported
video is converted to H.264; the converter changes incompatible audio to AAC and
text subtitles to `mov_text`. Standardizing an existing MP4 copies its audio and
subtitles. If a stream cannot be represented in MP4, the command fails and keeps
the original. Stream counts are checked before publication; that check is not a
proof of perceptual fidelity or complete decodability.

Output is staged beside its destination, given the original timestamp/mode and
published only after validation. Existing conversion destinations are skipped.
Image repair can keep `.CORRUPT` originals or mark unrepaired input `.BROKEN`;
review `MEDIA_KEEP_CORRUPT_ORIGINAL` and `MEDIA_MARK_UNREPAIRABLE` first.

`archive_source_files.sh --dry-run` writes its preview to the terminal and creates
no archive or log directory. The archive must be outside the scan tree. A
same-name MP4 is only an archive eligibility check; review the conversion output
before relying on that correspondence. Media `--check-config` creates no log.

## Ambiguous ECH publication

The ECH hook verifies a failed or uncertain PATCH with a
[Cloudflare record GET](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/get/).
If the new DNS value is confirmed, rotation completes. If the old value is
confirmed, local rotation rolls back. If neither can be established, the hook
returns failure, retains both generations of keys and IDs, and writes
`.npmplus_ech_cloudflare.pending`. Later rotations refuse to proceed.

Recovery is an operator action: pause the invoking schedule, inspect the named
record through an authenticated channel, and select the matching key **and ID**
generation named in the pending file. Restore those matching runtime files and
reload NPMplus using the deployment's normal procedure. Verify the record and
service agree before removing the marker and obsolete recovery copies and
resuming rotation. Do not delete the marker merely to silence the failure.
These recovery files contain private key material; never paste them into a
ticket or commit them. A failed local rollback likewise retains recovery data.
