# Changelog

All notable changes to Patch Gremlin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-08-21

A correctness and security release. Several long-standing bugs meant the
notifier could misreport what it had done, and the Doppler service token was
stored in world-readable files. **Re-run the installer after upgrading** so
the new secret layout and trigger wiring are applied.

### Breaking

- **Notifications are now triggered by the upgrade run finishing**
  (`ExecStartPost` on `apt-daily-upgrade.service` / `dnf-automatic.service`)
  rather than by a separate timer. The `update-notifier.timer` is still
  installed but **disabled by default**; set `ENABLE_HEARTBEAT=true` to get a
  scheduled report even when no upgrade ran.
- The `Dpkg::Post-Invoke` APT hook is removed. It fired after *every* dpkg
  invocation, so any `apt install` sent a notification. Existing installs have
  it deleted on upgrade.
- Secrets moved from the systemd unit and the APT hook into
  `/etc/update-notifier/env` (mode 600), referenced via `EnvironmentFile=`.
- `config.sh` is now parsed against an allowlist instead of being sourced.
  Command substitution in that file no longer works — see `config.example.sh`.
- `Unattended-Upgrade::Automatic-Reboot-WithUsers` now defaults to `false`.

### Fixed

- **Package detection never worked on real Debian logs.** unattended-upgrades
  writes the package list on the same line as the marker; the parser skipped
  that line and bailed on the next one, always returning an empty list. That
  emptiness then tripped a "correction" branch which flipped the status from
  `updated` to `no-updates` — so Patch Gremlin reported "No updates applied"
  on exactly the runs where it *had* applied updates.
- **The RHEL path aborted whenever updates existed.** `dnf check-update` exits
  100 when updates are available; with `set -e -o pipefail` that killed the
  notifier before it sent anything.
- **`health-check.sh` exited on the first problem it found.** `((ERRORS++))`
  returns status 1 when the counter goes 0→1, so `set -e` terminated the
  script before it printed a summary, and it exited 1 rather than the
  documented 2. Same defect in `test-deployment.sh`.
- **`monitoring/nagios-check.sh` could only ever report UNKNOWN.** It read
  `$?` inside `if ! cmd; then`, where `$?` is the status of the negation.
- **Both monitoring integrations referenced a script the installer never
  installed** (`/usr/local/bin/patch-gremlin-health-check.sh`).
- **The notifier and timer raced each other.** Both fired at `UPDATE_TIME`
  with independent `RandomizedDelaySec=30min`, so roughly half of all
  notifications described the previous run.
- `Requires=` in the timer's `[Unit]` section made systemd start the service
  the moment the timer started — a notification on every boot.
- Only one field was JSON-escaped; titles, summaries, hostnames, held-back
  package names and error strings were interpolated raw, so a single `"` in a
  log line produced a malformed payload and a failed delivery.
- Four `trap ... EXIT` handlers each replaced the previous one, leaking the
  log snapshot to `/tmp` on every run with Matrix enabled.
- `SECRET_MODE=local` crashed with `unbound variable` when the secrets file
  was missing or had unsafe permissions.
- `UPDATE_SCHEDULE=weekly` without `UPDATE_DAY` aborted mid-install with
  `UPDATE_DAY: unbound variable`, after the APT config had been rewritten.
- `SYSTEM_TIMEZONE` was documented but the preset path never applied it.
- `VERSION_ID` is unset on Debian testing/sid and aborted OS detection.
- A bare `$(hostname)` aborted the notifier under `set -e` on minimal
  Fedora/RHEL images, where `hostname` is a separate package and not installed.
  Resolution now falls back through `hostnamectl`, `$HOSTNAME`,
  `/proc/sys/kernel/hostname` and `/etc/hostname`, and
  `PATCH_GREMLIN_HOSTNAME` overrides it.
- `grep -c … || echo "0"` produced `"0\n0"` in `test-deployment.sh` and
  emitted an unparseable Prometheus metric in the exporter.
- `curl … || echo "\n000"` emitted a literal backslash-n, causing a bash
  arithmetic error in the HTTP status comparison.
- Backups were written into `/etc/apt/apt.conf.d/`, where APT logs an
  "invalid filename extension" warning on every invocation, once per file.
  They now go to `/var/backups/patch-gremlin/`; strays are relocated.
- `Automatic-Reboot-Time` was hardcoded to 03:00 regardless of `UPDATE_TIME`,
  so a 04:00 upgrade window waited ~23 hours to reboot.
- `uninstall.sh` had no root check and could install a blank root crontab.
- `diagnose-config.sh` could permanently leave `PATCH_GREMLIN_DRY_RUN=true`
  in a drop-in if interrupted, silently disabling all notifications.
- `test-deployment.sh` installed `vim-tiny` and ran `apt-get autoremove -y`
  on production hosts, printed "PASSED" unconditionally, and always exited 0.

### Security

- The Doppler service token was written to `/etc/systemd/system/update-notifier.service`
  and `/etc/apt/apt.conf.d/99patch-gremlin-notification`, both mode 0644, and
  was exposed by `systemctl show` to unprivileged users.
- `load_config_safely()` filtered `export` lines, warned if it saw a command
  substitution, then sourced the file anyway — so `export X="$(cmd)"` executed
  as root. `config.example.sh` actively recommended that pattern.
- The systemd unit is now hardened (`NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `PrivateTmp`, `RestrictSUIDSGID`, …).
- CI actions are pinned instead of tracking `@master`.

### Added

- **ntfy, Gotify and generic JSON webhook** notification targets.
- Ubuntu Pro / ESM origins for security-only mode — LTS hosts were silently
  skipping those updates.
- Split **security vs total** pending-update counts. The previous wording
  called every pending package "non-security", which was simply wrong.
- `--help`, `--version` and non-interactive flags on every script.
- Full unattended install: local-mode secrets can come from `LOCAL_*`
  environment variables instead of five blocking `read` prompts.
- `--update-only` now refreshes units and hooks, not just the notifier.
- `flock` serialisation, a machine-readable state file at
  `/var/lib/patch-gremlin/state`, and `PATCH_GREMLIN_NOTIFY_ON=changes`.
- Amazon Linux 2 (`yum-cron`) and Fedora 41+ (`dnf5-automatic`) support.
- Matrix `/v3` API, long-lived access tokens, and logout after password login
  (the old code registered a new device on every single run).
- Teams Adaptive Card payloads, replacing the retired MessageCard connector
  format.
- **A 107-test bats suite** plus CI that runs it on Debian 12/13,
  Ubuntu 22.04/24.04, Rocky 9 and Fedora 41. ShellCheck now gates at
  `-S style`, which catches the `$?`-after-assignment and `echo "\n"` classes
  of bug that shipped in 1.x.
- `SECURITY.md`, `CONTRIBUTING.md`, this changelog, and Dependabot for
  GitHub Actions.
- `PATCH_GREMLIN_OS_TYPE` forces the package-family branch, so both the Debian
  and RHEL installer paths are tested on every CI image rather than only the
  one matching the host.
- `tests/run.sh` as the canonical suite entry point; it detects which flags the
  local bats supports instead of assuming a recent version.

### Changed

- `fix-verbose-now.sh` is now a deprecation shim over
  `configure-verbosity.sh --quiet`.
- `configure-verbosity.sh` gained `--quiet`/`--verbose`/`--show`, is
  idempotent, and no longer needs GNU `grep -P`.

## [1.x]

Initial releases. See the git history for details.

[2.0.0]: https://github.com/ChiefGyk3D/Patch-Gremlin/releases/tag/v2.0.0
