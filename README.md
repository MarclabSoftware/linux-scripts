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
| [`tests/`](tests/)             | Dependency-free Bash tests                               |
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
   Account creation deliberately remains an OS-installation task.
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

## Standalone scripts and systemd units

For a standalone script, read its header and `--help` output first. When a
matching `*.env.example`, `*.conf.example` or `*.paths.example` exists, copy it
to the same name without `.example`, keep that real file private and run
`--check-config` when the script supports it.

Files such as `name@.service` are systemd templates. The text after `@` is the
instance value exposed as `%i`; the comment at the top of each unit states what
that value means and gives a concrete example. Review paths and permissions
before installing any public example under `/etc/systemd/system/`.

Private sidecars, generated artifacts, credentials and logs are excluded by
`.gitignore`. Check `git status` before every commit anyway.

## Development checks

The tests are development safeguards; they are not needed on managed servers
and are not included in the generated artifact. They exercise configuration,
rendered files, command construction, idempotency, rollback and the two-phase
state machine using temporary directories and fake system commands. They do not
contact the three real hosts or modify their services. The phase-state test uses
passwordless `sudo` only inside its temporary test tree and reports `skipped`
when that is unavailable.

Run every static check, test and secret scan from the repository root:

```bash
./check.sh
```

Run one test directly while working on its corresponding component:

```bash
bash tests/test_build.sh
bash tests/test_init_ssh.sh
```

No test framework is involved. A successful test prints a short confirmation;
an assertion failure stops with a non-zero exit status. Broadly, the tests cover
the artifact format and corruption checks (`test_build.sh`), the provisioner and
its modules (`test_init_*.sh`), and the standalone scripts (`test_*.sh`).

`./check.sh` runs strict ShellCheck (`--severity=style --enable=all`), shfmt,
Bash or Dash syntax checks, checkbashisms, all Bash tests and both
staged-content and repository-history secret scans with Gitleaks. It stops and
names any missing checker instead of silently skipping it.
