#!/bin/bash
#
# Prometheus textfile-collector exporter for Patch Gremlin.
# Install to /usr/local/bin and run from cron or a systemd timer:
#   */5 * * * * /usr/local/bin/prometheus-exporter.sh > /var/lib/node_exporter/patch_gremlin.prom.$$ \
#               && mv /var/lib/node_exporter/patch_gremlin.prom.$$ /var/lib/node_exporter/patch_gremlin.prom

set -uo pipefail

HEALTH_SCRIPT="${PATCH_GREMLIN_HEALTH_SCRIPT:-/usr/local/bin/patch-gremlin-health-check.sh}"
STATE_DIR="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}"

# Defaults so a missing/partial state file can never emit a blank or doubled
# metric value (the old `grep -c ... || echo 0` printed "0" twice).
last_run_epoch=0
last_status="unknown"
upgraded_count=0
pending_total=0
pending_security=0
notification_sent=false

read_state() {
    local file="$1" mode owner expected_owner line key value
    [[ -r "$file" && ! -L "$file" ]] || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null)" || return 1
    expected_owner=0; [[ $(id -u) -eq 0 ]] || expected_owner="$(id -u)"
    (( (8#$mode & 022) == 0 )) || return 1
    [[ "$owner" == "$expected_owner" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            last_run_epoch|upgraded_count|pending_total|pending_security)
                [[ "$value" =~ ^[0-9]+$ ]] && printf -v "$key" '%s' "$value" ;;
            last_status) [[ "$value" =~ ^(updated|updates-available|no-updates|error)$ ]] && last_status="$value" ;;
            notification_sent) [[ "$value" =~ ^(true|false)$ ]] && notification_sent="$value" ;;
        esac
    done < "$file"
}
[[ ! -r "$STATE_DIR/state" ]] || read_state "$STATE_DIR/state" || true

num() { local v="${1:-0}"; v="${v//[^0-9]/}"; printf '%s' "${v:-0}"; }

health=0
if [[ -x "$HEALTH_SCRIPT" ]] && "$HEALTH_SCRIPT" --quiet &>/dev/null; then
    health=1
fi

sent=0
[[ "${notification_sent:-false}" == "true" ]] && sent=1

echo "# HELP patch_gremlin_health Health status (1=healthy, 0=unhealthy)"
echo "# TYPE patch_gremlin_health gauge"
echo "patch_gremlin_health ${health}"

echo "# HELP patch_gremlin_last_run_timestamp_seconds Unix time of the last notifier run"
echo "# TYPE patch_gremlin_last_run_timestamp_seconds gauge"
echo "patch_gremlin_last_run_timestamp_seconds $(num "$last_run_epoch")"

echo "# HELP patch_gremlin_last_notification_success 1 if the last run delivered a notification"
echo "# TYPE patch_gremlin_last_notification_success gauge"
echo "patch_gremlin_last_notification_success ${sent}"

echo "# HELP patch_gremlin_packages_upgraded Packages upgraded during the last run"
echo "# TYPE patch_gremlin_packages_upgraded gauge"
echo "patch_gremlin_packages_upgraded $(num "$upgraded_count")"

echo "# HELP patch_gremlin_pending_updates Packages still awaiting upgrade"
echo "# TYPE patch_gremlin_pending_updates gauge"
echo "patch_gremlin_pending_updates $(num "$pending_total")"

echo "# HELP patch_gremlin_pending_security_updates Security packages still awaiting upgrade"
echo "# TYPE patch_gremlin_pending_security_updates gauge"
echo "patch_gremlin_pending_security_updates $(num "$pending_security")"

echo "# HELP patch_gremlin_status_info Last run status as a labelled info metric"
echo "# TYPE patch_gremlin_status_info gauge"
printf 'patch_gremlin_status_info{status="%s"} 1\n' "${last_status//[^a-z-]/}"
