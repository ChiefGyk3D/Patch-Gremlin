#!/bin/bash

# Prometheus metrics exporter for Patch Gremlin
# Run via cron every 5 minutes: */5 * * * * /path/to/prometheus-exporter.sh > /var/lib/node_exporter/patch_gremlin.prom

echo "# HELP patch_gremlin_health Health status (1=healthy, 0=unhealthy)"
echo "# TYPE patch_gremlin_health gauge"

# Health check
if /usr/local/bin/patch-gremlin-health-check.sh &>/dev/null; then
    echo "patch_gremlin_health 1"
else
    echo "patch_gremlin_health 0"
fi

echo "# HELP patch_gremlin_last_run_timestamp Unix timestamp of last notification attempt"
echo "# TYPE patch_gremlin_last_run_timestamp gauge"

# Last run timestamp from journal
last_run=$(journalctl -t patch-gremlin --since "7 days ago" -o short-unix | tail -1 | awk '{print $1}' | tr -d '[]')
echo "patch_gremlin_last_run_timestamp ${last_run:-0}"

echo "# HELP patch_gremlin_last_success_timestamp Unix timestamp of last successful notification"
echo "# TYPE patch_gremlin_last_success_timestamp gauge"

# Last success timestamp
last_success=$(journalctl -t patch-gremlin --since "7 days ago" | grep "SUCCESS: Notification delivery complete" | tail -1)
if [[ -n "$last_success" ]]; then
    success_time=$(echo "$last_success" | awk '{print $1" "$2" "$3}')
    success_epoch=$(date -d "$success_time" +%s 2>/dev/null || echo 0)
    echo "patch_gremlin_last_success_timestamp $success_epoch"
else
    echo "patch_gremlin_last_success_timestamp 0"
fi

echo "# HELP patch_gremlin_updates_total Total number of package updates detected"
echo "# TYPE patch_gremlin_updates_total counter"

# Count updates from logs
update_count=$(journalctl -t patch-gremlin --since "30 days ago" | grep -c "package(s) updated" || echo 0)
echo "patch_gremlin_updates_total $update_count"
