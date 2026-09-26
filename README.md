# linux-scripts

Reusable Linux administration scripts and an optional host provisioner for
Arch Linux, Debian and Raspberry Pi OS.

The repository has two independent parts:

- [`src/scripts/`](src/scripts/) contains standalone operational scripts.
- [`src/init/`](src/init/) contains the two-phase provisioner. [`build.sh`](build.sh)
  packages it with one private configuration into a single text file that can
  be pasted into an SSH session.

Standalone scripts are not included in the provisioning artifact.

## Repository layout

| Path                           | Purpose                                                  |
| ------------------------------ | -------------------------------------------------------- |
| [`src/init/`](src/init/)       | Provisioning engine and documented configuration example |
| [`src/scripts/`](src/scripts/) | Standalone maintenance and automation scripts            |
| [`systemd/`](systemd/)         | Generic example services, timers and paths               |
| [`udev/`](udev/)               | Generic example udev rules                               |
| [`tests/`](tests/)             | Bash tests with temporary fixtures and fake system commands |
| [`build.sh`](build.sh)         | Builds one private, pasteable provisioning artifact      |
| [`check.sh`](check.sh)         | Runs every repository check                              |

## Provision a host

Run the following commands from the repository root.

### 1. Create the private configuration

```bash
cp -- src/init/init.env.example src/init/init.env
chmod 0600 src/init/init.env
nano src/init/init.env
```

Before continuing:

1. Replace `CONFIG_USER` with an existing, non-root account on the target.
   Create that account during OS installation.
2. Read the comments beside every option you enable.
3. Leave unused `CONFIG_INIT_*` switches set to `false`.
4. Never put private SSH keys, passwords or tokens in this file.

The configuration is Bash syntax and is trusted as administrator-controlled
code. Do not use a file received from an untrusted source.

### 2. Build the artifact

```bash
./build.sh
```

The build validates the configuration and creates:

```text
build/linux-init.sh
```

Only `init.sh`, the modules explicitly listed in `PAYLOAD_FILES` in `build.sh`,
and the selected configuration are packaged. Notes, backup copies and unrelated
files in `src/init/` are excluded. Add a new provisioning module to that list
when wiring it into `init.sh`.

The output is one executable, text-only file with mode `0700`. It contains the
complete private configuration, so treat it as a secret. Base64 makes terminal
transport reliable; it does not encrypt anything. The pasted wrapper protects
Bash history, but the clipboard and terminal scrollback can still retain it.

To keep separate configurations for several hosts, use the already ignored
`private/` directory and choose an explicit output name:

```bash
mkdir -p private/my-host
cp -- src/init/init.env.example private/my-host/init.env
chmod 0600 private/my-host/init.env
nano private/my-host/init.env
./build.sh \
    --config private/my-host/init.env \
    --output build/linux-init-my-host.sh
```

### 3. Paste it into the target

Open an interactive SSH session and make sure the remote prompt is Bash:

```bash
ssh HOST
bash
```

In a second, local terminal, print the generated file:

```bash
cat -- build/linux-init.sh
```

Copy every line, from the first shebang to the final `fi`, paste the whole block
once at the remote Bash prompt, then press Enter. Do not copy only the Base64
payload and do not split the block across separate shells.

With no arguments, the artifact performs a read-only preflight first. If it
passes, provisioning starts immediately and obtains root privileges through
`sudo` when necessary. Preflight failure stops before provisioning.

> Provisioning is not a dry run: phase 1 always performs a complete operating
> system update before applying any enabled configuration.

### 4. Reboot and finish

The first successful run performs the update and all pre-reboot actions. It
does not reboot automatically. When instructed, run:

```bash
sudo reboot
```

After the machine has really rebooted, reconnect and paste the same, unchanged
artifact again. The second run performs enabled post-reboot operations such as
Docker login, custom network creation, restore and Compose startup, then removes
the phase marker.

The second run is required even when no post-reboot option is enabled. Running
the artifact a third time starts a new provisioning cycle.

## Checks and recovery

| Command                                | Changes the host? | Purpose                                                                 |
| -------------------------------------- | ----------------- | ----------------------------------------------------------------------- |
| `./build.sh`                           | No                | Validate the selected configuration and build the artifact              |
| `./build/linux-init.sh --check-config` | No                | Validate the configuration embedded in the artifact                     |
| `./build/linux-init.sh --preflight`    | No                | Check the current target account, package manager and SSH prerequisites |
| `./build/linux-init.sh`                | Yes               | Run preflight, then the correct provisioning phase                      |
| `./build/linux-init.sh --help`         | No                | Show provisioner options                                                |

If a paste is truncated or altered, the checksum fails before extraction; paste
the complete artifact again. If phase 1 fails, fix the reported problem and run
the same artifact again. After phase 1 succeeds, a real reboot is mandatory. If
phase 2 fails, fix the problem and rerun the same artifact after that reboot.

The provisioner uses an exclusive lock and stores its phase marker under
`/var/lib/linux-scripts/`. Do not delete the marker merely to bypass the reboot
check.

## What the provisioner can manage

Every optional action is documented in
[`src/init/init.env.example`](src/init/init.env.example). Available modules
cover:

- full system updates, official packages, orphan removal and package caches;
- journal limits, rfkill, swap policy and native zram-generator setup;
- user groups, validated passwordless sudo, Bash, Readline, fzf and Nano;
- network sysctls, periodic fstrim, Chrony or systemd-timesyncd, and
  systemd-resolved;
- Raspberry Pi EEPROM updates and managed boot configuration;
- SSH public keys, verified known hosts and optional hardening;
- Docker installation, daemon policy, service startup, registry login, a custom
  bridge, controlled restore and Compose startup.

SSH hardening is intentionally high impact: its first successful run rotates
the server host keys, so clients must verify the printed fingerprints and
update their `known_hosts` entries. Restore options can overwrite files below
their configured destination. Review both sections especially carefully.

Repeated Docker, resolver, NTP and SSH configuration avoids unnecessary service
reloads when the managed policy is unchanged. Validation still runs; an explicit
SSH rotation request rotates keys. Provisioning switches control Docker
activation.

## Standalone scripts and systemd units

For a standalone script, read its header and `--help` output first. When a
matching `*.env.example`, `*.conf.example` or `*.paths.example` exists, copy it
to the same name without `.example`, keep that real file private and run
`--check-config` when the script supports it.

Use the [operational guide](src/scripts/README.md) for dependencies, privileges,
dry-run behavior and failure recovery. Use the [systemd installation guide](systemd/README.md)
for the files needed alongside each unit. No blanket installation of every
script or unit is needed.

Files such as `name@.service` are systemd templates. The text after `@` is the
instance value exposed as `%i`; the comment at the top of each unit states what
that value means and gives a concrete example. Review paths and permissions
before installing any public example under `/etc/systemd/system/`.

Private sidecars, generated artifacts, credentials and logs are excluded by
`.gitignore`. Check `git status` before every commit anyway.

### Standalone component catalog

| Component | Purpose | Configuration / integration |
| --- | --- | --- |
| `cert_monitor.sh` | Export NPM/NPMplus certificates | `.env`, service |
| `clone_disk.sh` | Clone a live Linux system disk | CLI |
| `cold_backup.sh` | Copy selected data to cold storage | `.env` |
| `devices.sh` | Inventory attached USB devices | CLI |
| `docker_network.sh` | Reconcile a Docker bridge | `.env`, service |
| `ethtool_optimizations.sh` | Apply interface offload settings | `.env`, service |
| `geo_ip_downloader.sh` + `ip_blocker.sh` | Add GeoIP/SSH filtering in a dedicated native nftables table | firewall `.env`, optional downloader tuning, service, timer |
| `media/` | Validate, convert and archive media | two `.env` files |
| `mtls_certificates.sh` | Create one RSA-4096 private CA and one shared mTLS identity | One command, password files |
| `npmplus_ech_cloudflare.sh` | Publish rotating NPMplus ECH keys to Cloudflare | owner-only `.env`, NPMplus cron hook |
| `power_state.sh` | Publish power state over a Mosquitto Unix socket | `.env`, `.conf`, service, udev rule |
| `ssh_audit.sh` | Update and run the latest upstream `ssh-audit` | user cache |
| `update_arch.sh` | Apply Arch Linux updates with configured exclusions | `.env`, `.paths` |
| `update_debian.sh` | Apply Debian updates with configured exclusions | `.env`, `.paths` |
| `update_zbdonglee.sh` | Update supported Zigbee coordinators | `.env` |
| Vaultwarden backup scripts | Send, receive and restore consistent archives over SSH | `.env` files, service, timer |
| `webos_devmode.sh` | Renew LG webOS Developer Mode | `.env`, service, timer |
| Console and keyboard-backlight units | Native console and LED controls | units only |
| Unbound units | Cache dump, CA reload and root hints update | units; root hints also needs `unbound_update_root_hints.sh` |
| `npm_cleaner.sh` | Clean Certbot CSR/key files and certificate archive versions | `.env`, dry run by default |
| `argonone_install.sh`, `pigpiod_install.sh` | Hardware-specific installers | CLI |

`media_common.sh` is a sourced library; every other `.sh` file under `src/scripts/`
is an executable entry point. `clone_disk.sh` is storage-layout-sensitive and
must be reviewed before use on a different system.

## Development checks

Use Linux, Bash 4.4 or newer, GNU coreutils/findutils and util-linux. The scripts
use Linux-specific interfaces and GNU options; this is not a macOS or BusyBox
suite. The ECH hook is POSIX shell and is also checked with Dash. Additional
component requirements are listed in the operational and systemd guides.

Tests are not installed on managed servers or included in provisioning builds.
They use temporary fixtures and fake system commands. Media tests also run real
FFmpeg on generated sample files; SQLite, swap-file and archive checks operate
only on synthetic data. A passing suite is not a live restore, firewall,
firmware or physical-device acceptance test.

Run every static check, test and secret scan from the repository root:

```bash
./check.sh
```

Select only the work needed during development; selectors can be combined:

```bash
./check.sh --static
./check.sh --tests
./check.sh --static --tests
./check.sh --secrets
```

`--static` needs ShellCheck, shfmt, Dash, checkbashisms and Git. Tests check their
own tool requirements, including FFmpeg/ffprobe, Python 3, OpenSSL, SQLite,
rsync and systemd-analyze where used. `--secrets` needs Gitleaks and intentionally
reads committable files, staged changes and Git history. Omit that selector when
history or potentially private content is outside the review scope; neither
`--static` nor `--tests` invokes a secret scan.

Run one test directly while working on its corresponding component:

```bash
bash tests/test_build.sh
bash tests/test_init_ssh.sh
```

No test framework is involved. The runner reports PASS, FAIL and SKIP separately,
continues after a failed test, then returns failure if any test failed. Exit 77
means a prerequisite is unavailable, not a passing test. The phase-state, firewall-lock and pre-update backup tests need root or the
elevation mechanism they describe; never
run the complete suite as root merely to satisfy those tests. Broadly, tests cover
the artifact format and corruption checks (`test_build.sh`), the provisioner and
its modules (`test_init_*.sh`), and the standalone scripts (`test_*.sh`).

Static checks include strict ShellCheck (`--severity=style --enable=all`), shfmt,
shell syntax, executable modes and example configuration syntax. Unit tests also
parse the systemd units in a synthetic installation without starting services.

## Maintenance conventions

Keep standalone scripts deployable on their own. Share code within the existing
provisioning and media families; avoid a mandatory utility installation for
every unrelated command. A sourced helper must document its arguments, caller
state and return behavior. Check mutating commands explicitly when a function
can run in `if`, `!` or `||`: Bash disables `errexit` inside those calls.

Keep path arguments quoted, use NUL-delimited file lists, preserve command exit
statuses and restore any shell options changed by a helper. Publish validated
temporary output on the destination filesystem; preserve recovery copies until
the full operation succeeds. A failed recovery must name the retained files
and return failure. Add a focused failure-injection check for these paths.

Headers and READMEs describe current purpose, configuration and operational
effects. Keep change history and migration narratives in Git, not in usage
guides. Manually maintained per-file release numbers are omitted.
Keep examples free of credentials and installation-specific private values.
