# systemd integration

These are system units, not user-manager units. Install only the service and
trigger selected for a particular host. Each template documents its instance:
usually the account owning `/home/ACCOUNT/scripts`, or the Unbound service and
configuration name. An account instance is not a path or arbitrary hostname.

## Companion files

| Templates | Install beside the unit / prepare first |
| --- | --- |
| `cert_monitor@.service` | `cert_monitor.sh`, private `.env`, certificate read access and PFX output access |
| `docker_network@.service` | `docker_network.sh`, `.env`, Docker service and account socket access |
| `ethtool_optimizations@.service` | `ethtool_optimizations.sh`, `.env`, ethtool; runs as root |
| `ip_blocker@.service` + `.timer` | Both firewall/downloader scripts, firewall sidecar, configured list trees, iprange and native nftables |
| `power_state@.service` | `power_state.sh`, `.env`, private Mosquitto options, socket access and the matching udev rule |
| `vaultwarden_backup@.service` + `.timer` | Sender script/sidecar, source data and SSH key; receiver/recovery sidecar on the peer |
| `webos_devmode@.service` + `.timer` | Script/sidecar and SSH key; the unit owns a private StateDirectory for cached state |
| `unbound_ca_bundle_reload@.path` + `.service` | Unbound control socket and distribution-specific CA bundle paths |
| `unbound_cache_dump@.service` + `.timer` | Writable `/var/lib/INSTANCE`, Unbound account and control socket |
| `unbound_roothints@.service` + `.timer` | Root-hints helper at the exact libexec path below; Unbound config and control socket |
| `kbd_backlight_off@.service` | Actual sysfs LED name as the escaped instance; no script |
| `getty@.service.d/` | Getty drop-in; applies console blanking and powerdown through optional `setterm` commands |

`cert_monitor` reads its `.env` through `EnvironmentFile=`. Keep that file
compatible with systemd's environment syntax. Other script-specific sidecars
are normally sourced by the script; do not put arbitrary shell syntax in a file
also consumed as a systemd `EnvironmentFile=`.

The templates use recent systemd sandboxing. The power-state retry settings
require systemd 254 or newer
([upstream directive definition](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml)).
The Unbound CA helper requires `fast_reload` support
([Unbound 1.23.0 or newer](https://www.nlnetlabs.nl/news/2025/Apr/24/unbound-1.23.0-released/)).
That command needs a threaded build and has configuration limitations and extra
temporary memory use; review the
[Unbound control manual](https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound-control.html).
Check these features on the target before enabling the corresponding unit.

## Install and validate a selected pair

First install the component's script and configuration. In the following webOS
example, replace `ACCOUNT` with the real account owning the scripts directory.
Run the commands from the repository root:

```bash
sudo install -m 0644 systemd/webos_devmode@.service systemd/webos_devmode@.timer /etc/systemd/system/
sudo systemctl daemon-reload
systemd-analyze verify webos_devmode@ACCOUNT.service webos_devmode@ACCOUNT.timer
```

Validate the concrete instance so systemd checks its actual executable path.
A manual run performs the real operation:

```bash
sudo systemctl start webos_devmode@ACCOUNT.service
systemctl status webos_devmode@ACCOUNT.service
sudo systemctl enable --now webos_devmode@ACCOUNT.timer
systemctl list-timers webos_devmode@ACCOUNT.timer
```

Use the equivalent selected service/trigger for other components. Timers and
paths select their same-name service; do not add an unnecessary `Unit=`.
One-shot services can be inactive after successful completion; check their exit
result and actual output. A loaded unit or an active timer does not prove that
the underlying backup, DNS update or device action succeeded.

The firewall is ordered after `network.target`, without waiting for Docker or
`network-online.target`. This is not a connectivity guarantee: actual sources
have bounded download attempts and validated per-source caches. A failed run is
retried after 60 seconds without a start-limit cutoff; successful runs keep the
timer's schedule (first attempt 20 seconds after timer activation, then every
four hours). Missing required data prevents replacement of live rules.

This deliberately does not persist firewall tables across reboots or promise
protection before the first successful run. Keep the router/OCI access policy
in force. Missing flowtable interfaces only disable offload; they do not block
the base filter. See the [firewall guide](../src/scripts/README.md#firewall)
for policy, cache handling, NAT and flow offload.

## Root-hints helper installation and recovery

The root-hints unit invokes `unbound_update_root_hints.sh` to download, validate
and publish hints, with rollback on failure. Install the helper and units before
enabling the timer. This example uses the `unbound` instance:

```bash
sudo install -d -m 0755 /usr/local/libexec/linux-scripts
sudo install -m 0755 src/scripts/unbound_update_root_hints.sh /usr/local/libexec/linux-scripts/unbound_update_root_hints.sh
sudo install -m 0644 systemd/unbound_roothints@.service systemd/unbound_roothints@.timer /etc/systemd/system/
sudo systemctl daemon-reload
systemd-analyze verify unbound_roothints@unbound.service unbound_roothints@unbound.timer
```

For the normal `unbound` instance, the unit uses `/etc/unbound/root.hints`,
`/etc/unbound/unbound.conf` and `/run/unbound/unbound.ctl`. Confirm that these
match the existing installation; adapt a drop-in if they differ. The service
needs curl, unbound-checkconf and unbound-control. It publishes a mode-0644 file
only after a successful download; unchanged hints do not trigger a reload.

After publication, the helper checks configuration and reloads Unbound. On
failure it restores the previous inode, ownership and permissions, then reloads
the previous configuration. If recovery also fails, `.root-hints.*` beside the
destination contains the previous and candidate files and the service fails.
Keep that directory until the chosen hints, configuration and actual DNS service
have been checked. No automatic deletion of failed recovery data is scheduled.

## Local development verification

`bash tests/test_systemd_units.sh` checks template/trigger conventions and asks
systemd-analyze to parse the units in a temporary synthetic installation. Dummy
executables satisfy missing host packages; no service is started. The separate
root-hints test injects download, validation, reload and rollback failures.
These checks do not replace validation on the deployment host.
