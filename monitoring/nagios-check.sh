#!/bin/bash

# Nagios/Icinga check for Patch Gremlin
# Returns: OK(0), WARNING(1), CRITICAL(2), UNKNOWN(3)

HEALTH_SCRIPT="/usr/local/bin/patch-gremlin-health-check.sh"
LAST_SUCCESS_HOURS=25  # Alert if no successful run in 25+ hours

# Check if health script exists
if [[ ! -x "$HEALTH_SCRIPT" ]]; then
    echo "UNKNOWN - Health check script not found: $HEALTH_SCRIPT"
    exit 3
fi

# Run health check
if ! output=$($HEALTH_SCRIPT 2>&1); then
    exit_code=$?
    case $exit_code in
        1) echo "WARNING - $output"; exit 1 ;;
        2) echo "CRITICAL - $output"; exit 2 ;;
        *) echo "UNKNOWN - Health check failed with code $exit_code"; exit 3 ;;
    esac
fi

# Check last successful notification
last_success=$(journalctl -t patch-gremlin --since "48 hours ago" | grep "SUCCESS: Notification delivery complete" | tail -1)
if [[ -z "$last_success" ]]; then
    echo "WARNING - No successful notifications in last 48 hours"
    exit 1
fi

# Extract timestamp and check age
timestamp=$(echo "$last_success" | awk '{print $1" "$2" "$3}')
if command -v date &>/dev/null; then
    last_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)
    current_epoch=$(date +%s)
    hours_ago=$(( (current_epoch - last_epoch) / 3600 ))
    
    if [[ $hours_ago -gt $LAST_SUCCESS_HOURS ]]; then
        echo "WARNING - Last successful notification was $hours_ago hours ago"
        exit 1
    fi
fi

echo "OK - Patch Gremlin healthy, last success: $timestamp"
exit 0
