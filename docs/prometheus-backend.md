# Prometheus textfile backend

Set `ENABLE_PROMETHEUS=true` during setup to install a five-minute systemd
timer. It runs `patch-gremlin-prometheus-textfile.sh`; it never runs the
notifier. `PROMETHEUS_TEXTFILE_DIR` selects the node_exporter textfile
directory and defaults to `/var/lib/node_exporter/textfile_collector`.

The collector strictly parses the state file and writes
`patch_gremlin.prom` with a temporary file plus atomic rename. Missing,
unsafe, or older-than-36-hours state produces an explicit `unknown` one-hot
status. `PATCH_GREMLIN_STATE_STALE_SECONDS` changes that threshold.

It exports the issue #56 metric names, including both
`patch_gremlin_reboot_required` and the compatibility alias
`node_reboot_required`. Pending packages are labeled `all`, `security`, and
`proxmox`; apt simulation output supplies the counts.
