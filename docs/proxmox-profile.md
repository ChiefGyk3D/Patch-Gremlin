# Proxmox profile

The opt-in Proxmox profile configures Patch Gremlin as the Debian security
update and notification layer on a Proxmox VE node.

```bash
sudo ./setup-unattended-upgrades.sh --profile proxmox
```

The profile writes `/etc/apt/apt.conf.d/99zz-patch-gremlin-proxmox`. It does not
replace the packaged `/etc/apt/apt.conf.d/50unattended-upgrades` conffile. The
final drop-in clears earlier origin lists, permits only the two explicit Debian
security origin patterns, and explicitly disables unauthenticated packages. It
also disables automatic reboot, automatic dependency removal, and unused
kernel package removal. Setup uses `apt-config dump` as the source of the
effective policy and fails if `Allowed-Origins` contains any entry or if
`Origins-Pattern` differs from those two patterns. This includes fragments
whose names end in `.conf`.

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
remain at least the requested number of minutes apart. The profile also sets
`Persistent=false`, so a missed slot is not replayed when a node boots.

## Cluster lock and service restarts

On a clustered node, `apt-daily-upgrade.service` acquires
`/etc/pve/priv/patch-gremlin-upgrade.lock` before it starts. A lock held by
another node skips that automatic upgrade run. The shared lock records the
node name and a random invocation ID, and the acquiring node stores the same
value in a local runtime marker. Cleanup removes the lock only when both values
match. An incomplete lock with no owner record is eligible for cleanup after
24 hours. A valid owned lock is never removed as stale because its owner cannot
be proven inactive without contacting that node. When `/etc/pve/corosync.conf`
is absent, or the shared `/etc/pve/priv` path is unavailable, the check logs
the condition and allows the upgrade to continue. This fail-open behavior
keeps standalone nodes and a node with an unavailable cluster filesystem from
being permanently blocked.

INFERRED: `/etc/pve/priv` is root-only cluster configuration storage, and an
atomic directory creation there acts as cluster-wide exclusion. The behavior
has not been exercised on a live cluster in this repository's sandbox.

The profile sets `NEEDRESTART_MODE=l` for the upgrade service and installs a
needrestart drop-in that keeps needrestart in list-only mode. It explicitly
excludes `corosync`, `pve-cluster`, `pveproxy`, `pvedaemon`, and `pvestatd` from
automatic restart selection. Package maintainer scripts remain outside
needrestart's control, so operators must still review package behavior.

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
sudo apt-config dump | grep -E 'Unattended-Upgrade::(Allowed-Origins|Origins-Pattern|Automatic-Reboot|Remove-Unused)|APT::Get::AllowUnauthenticated'
systemctl cat apt-daily-upgrade.timer
systemctl cat apt-daily-upgrade.service
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
