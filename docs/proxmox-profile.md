# Proxmox profile

The opt-in Proxmox profile configures Patch Gremlin as the Debian security
update and notification layer on a Proxmox VE node.

```bash
sudo ./setup-unattended-upgrades.sh --profile proxmox
```

The profile writes `/etc/apt/apt.conf.d/52patch-gremlin-proxmox`. It does not
replace the packaged `/etc/apt/apt.conf.d/50unattended-upgrades` conffile. The
late drop-in permits Debian security origins only and explicitly does not add
Proxmox repositories. It also disables automatic reboot, automatic dependency
removal, and unused kernel package removal.

## Scope and update policy

Patch Gremlin automatically applies Debian security updates. It reports
pending Proxmox packages, but never installs them. Apply Proxmox updates
manually with the rolling updater, one node at a time, using the update method
recommended for the installed Proxmox release.

The profile does not migrate workloads, choose a maintenance order, run a
cluster rolling update, or reboot a node. A running node keeps its installed
Proxmox kernels because unattended-upgrades is not allowed to remove unused
kernel packages or dependencies.

## Staggered schedules

Use a deterministic slot for each node:

```bash
sudo ./setup-unattended-upgrades.sh --profile proxmox \
  --stagger-minutes 60 --stagger-index 2
```

`--stagger-minutes` must be at least 60, and `--stagger-index` is zero-based.
Both options are required together. The calculated time must remain within the
same day. A configured stagger sets `RandomizedDelaySec=0`, so adjacent slots
remain at least the requested number of minutes apart.

## Reboot policy and metrics

Reboots remain manual. The Prometheus textfile collector reads
`/var/run/reboot-required` and `/var/run/reboot-required.pkgs`; it never creates
or removes either file. It exports:

- `patch_gremlin_pending_packages{kind="all"}`
- `patch_gremlin_pending_packages{kind="security"}`
- `patch_gremlin_pending_packages{kind="proxmox"}`
- `patch_gremlin_held_back_packages`
- `patch_gremlin_reboot_required`
- `node_reboot_required`
- `patch_gremlin_reboot_required_packages`

Repository classification comes from strict parsing of `apt-cache policy`
candidate rows. Package names and policy text are never evaluated as shell
input.

## Verification

Review the effective unattended-upgrades policy and timer:

```bash
sudo apt-config dump | grep -E 'Unattended-Upgrade::(Origins-Pattern|Automatic-Reboot|Remove-Unused)'
systemctl cat apt-daily-upgrade.timer
systemctl list-timers apt-daily-upgrade.timer
```

Verify the collector output after enabling the Prometheus backend:

```bash
sudo systemctl start patch-gremlin-prometheus.service
sudo grep -E 'pending_packages|held_back|reboot_required' \
  /var/lib/node_exporter/textfile_collector/patch_gremlin.prom
```

Before a manual rolling update, inspect pending packages and their origins:

```bash
apt list --upgradable
apt-cache policy PACKAGE_NAME
```
