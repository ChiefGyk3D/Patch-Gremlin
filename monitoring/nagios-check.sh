#!/bin/bash
#
# Nagios/Icinga check for Patch Gremlin
# Returns: OK(0), WARNING(1), CRITICAL(2), UNKNOWN(3)

set -uo pipefail

HEALTH_SCRIPT="${PATCH_GREMLIN_HEALTH_SCRIPT:-/usr/local/bin/patch-gremlin-health-check.sh}"
STATE_DIR="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}"
MAX_AGE_HOURS="${PATCH_GREMLIN_MAX_AGE_HOURS:-25}"

if [[ ! -x "$HEALTH_SCRIPT" ]]; then
    echo "UNKNOWN - Health check script not found: $HEALTH_SCRIPT"
    exit 3
fi

# Capture status explicitly. `if ! cmd; then ... $? ...` reports the status of
# the negation (always 0), so the previous version could only ever emit
# UNKNOWN no matter what the health check returned.
output="$("$HEALTH_SCRIPT" --quiet 2>&1)"
rc=$?

case $rc in
    0) ;;
    1) echo "WARNING - ${output:-health check reported a warning}"; exit 1 ;;
    2) echo "CRITICAL - ${output:-health check reported a failure}"; exit 2 ;;
    *) echo "UNKNOWN - Health check exited with code $rc"; exit 3 ;;
esac

# Freshness, from the state file the notifier writes on every run.
if [[ ! -r "$STATE_DIR/state" ]]; then
    echo "WARNING - No Patch Gremlin state file at $STATE_DIR/state"
    exit 1
fi

last_run_epoch=0
last_status="unknown"
# shellcheck source=/dev/null
source "$STATE_DIR/state" 2>/dev/null || true

if [[ "${last_run_epoch:-0}" -le 0 ]]; then
    echo "WARNING - State file has no recorded run"
    exit 1
fi

age_hours=$(( ( $(date +%s) - last_run_epoch ) / 3600 ))
if [[ $age_hours -gt $MAX_AGE_HOURS ]]; then
    echo "WARNING - Last run was ${age_hours}h ago (threshold ${MAX_AGE_HOURS}h)"
    exit 1
fi

echo "OK - Patch Gremlin healthy | last_run_age_hours=${age_hours} status=${last_status} pending=${pending_total:-0} pending_security=${pending_security:-0}"
exit 0
