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
| `getty@.service.d/` | Getty drop-in only; retains the existing optional `setterm` powerdown behavior |

`cert_monitor` reads its `.env` through `EnvironmentFile=`. Keep that file
compatible with systemd's environment syntax. Other script-specific sidecars
are normally sourced by the script; do not put arbitrary shell syntax in a file
also consumed as a systemd `EnvironmentFile=`.

The templates use recent systemd sandboxing. The power-state retry settings
require systemd 254 or newer
([upstream directive definition](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml)).
The Unbound CA helper uses `fast_reload`, introduced in
[Unbound 1.23.0](https://www.nlnetlabs.nl/news/2025/Apr/24/unbound-1.23.0-released/).
That command needs a threaded build and has configuration limitations and extra
temporary memory use; review the
[Unbound control manual](https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound-control.html).
Check these features on the target before enabling the corresponding unit.

## Install and validate a selected pair

From the repository root, an example for the webOS timer is:

```bash
sudo install -m 0644 systemd/webos_devmode@.service systemd/webos_devmode@.timer /etc/systemd/system/
sudo systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/webos_devmode@.service /etc/systemd/system/webos_devmode@.timer
```

First install its script/configuration and substitute the real account for
`ACCOUNT`. A manual run performs the real operation:

```bash
sudo systemctl start webos_devmode@ACCOUNT.service
systemctl status webos_devmode@ACCOUNT.service
sudo systemctl enable --now webos_devmode@ACCOUNT.timer
systemctl list-timers webos_devmode@ACCOUNT.timer
```

Use the equivalent selected service/trigger for other components. Timers and
paths already select their same-name service; do not add an unnecessary `Unit=`.
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
the base filter. For upgrades from iptables or generic NAT, follow the
[firewall migration instructions](../src/scripts/README.md#firewall-updates).

## Root-hints helper installation and recovery

The root-hints unit now uses a separate executable so its update and rollback
can be checked together. Install both the script and unit before enabling it:

```bash
sudo install -d -m 0755 /usr/local/libexec/linux-scripts
sudo install -m 0755 src/scripts/unbound_update_root_hints.sh /usr/local/libexec/linux-scripts/unbound_update_root_hints.sh
sudo install -m 0644 systemd/unbound_roothints@.service systemd/unbound_roothints@.timer /etc/systemd/system/
sudo systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/unbound_roothints@.service
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
