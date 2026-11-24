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
pending_total=0
pending_security=0
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
            last_run_epoch|pending_total|pending_security)
                [[ "$value" =~ ^[0-9]+$ ]] && printf -v "$key" '%s' "$value" ;;
            last_status) [[ "$value" =~ ^(updated|updates-available|no-updates|error)$ ]] && last_status="$value" ;;
        esac
    done < "$file"
}
if ! read_state "$STATE_DIR/state"; then
    echo "WARNING - State file failed safety validation"
    exit 1
fi

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
