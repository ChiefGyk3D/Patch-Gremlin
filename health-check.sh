#!/bin/bash
#
# Patch Gremlin Health Check
# Quick validation of system configuration and connectivity.
# Exit codes: 0=healthy, 1=warning, 2=critical
#
# Designed to be called from Nagios/Icinga/Zabbix or a cron job.

set -uo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

NOTIFIER="${PATCH_GREMLIN_NOTIFIER:-/usr/local/bin/update-notifier.sh}"
SERVICE_DIR="${PATCH_GREMLIN_SERVICE_DIR:-/etc/systemd/system}"
CONFIG_DIR="${PATCH_GREMLIN_CONFIG_DIR:-/etc/update-notifier}"

WARNINGS=0
ERRORS=0

usage() {
    cat <<EOF
Patch Gremlin health check v${PATCH_GREMLIN_VERSION}

Usage: health-check.sh [-q|--quiet] [-h|--help]

Exit codes: 0 = healthy, 1 = warning, 2 = critical
EOF
}

QUIET=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quiet) QUIET=true ;;
        -h|--help)  usage; exit 0 ;;
        -V|--version) echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

log() {
    [[ "$QUIET" == "true" ]] && return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# NB: `((ERRORS++))` returns exit status 1 when the counter goes 0->1, because
# post-increment yields the OLD value. Under `set -e` that killed this script
# on the very first problem it found, before it printed anything. Plain
# assignment always returns 0.
add_error()   { ERRORS=$((ERRORS + 1)); }
add_warning() { WARNINGS=$((WARNINGS + 1)); }

check_file() {
    local file="$1" desc="$2"
    if [[ -f "$file" ]]; then
        log "✓ $desc exists: $file"
        return 0
    fi
    log "✗ $desc missing: $file"
    add_error
    return 1
}

check_timer() {
    local unit="$1"
    if systemctl is-active "$unit" &>/dev/null; then
        log "✓ Timer active: $unit"
        return 0
    elif systemctl list-unit-files "$unit" &>/dev/null; then
        log "⚠ Timer inactive: $unit"
        add_warning
        return 1
    fi
    log "✗ Timer not found: $unit"
    add_error
    return 2
}

log "=== Patch Gremlin Health Check ==="

check_file "$NOTIFIER" "Notification script"
check_file "$SERVICE_DIR/update-notifier.service" "Systemd service"
check_file "$SERVICE_DIR/update-notifier.timer" "Systemd timer"

check_timer "update-notifier.timer"

# Secret backend
if [[ -f "$CONFIG_DIR/secrets.conf" ]]; then
    log "✓ Local secrets file present"
    perms="$(stat -c '%a' "$CONFIG_DIR/secrets.conf" 2>/dev/null || echo "???")"
    if [[ "$perms" == "600" ]]; then
        log "✓ Secrets file permissions are 600"
    else
        log "⚠ Secrets file permissions are $perms (expected 600)"
        add_warning
    fi
elif [[ -f "$CONFIG_DIR/env" ]]; then
    log "✓ Doppler environment file present"
    perms="$(stat -c '%a' "$CONFIG_DIR/env" 2>/dev/null || echo "???")"
    if [[ "$perms" == "600" ]]; then
        log "✓ Environment file permissions are 600"
    else
        log "⚠ Environment file permissions are $perms (expected 600)"
        add_warning
    fi
    if ! command -v doppler &>/dev/null; then
        log "⚠ Doppler CLI not found"
        add_warning
    fi
fi

# Dry-run the notifier. Check the command directly rather than via $? - under
# `set -e` an assignment from a failing command exits before $? is read.
if [[ -x "$NOTIFIER" ]]; then
    log "Testing notification script (dry run)..."
    if test_output="$(PATCH_GREMLIN_DRY_RUN=true "$NOTIFIER" 2>&1)"; then
        log "✓ Notification script test passed"
    else
        log "✗ Notification script test failed: $(printf '%s' "$test_output" | head -1)"
        add_error
    fi
fi

# Freshness of the last run, from the state file the notifier writes.
STATE_DIR="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}"
if [[ -r "$STATE_DIR/state" ]]; then
    last_run_epoch=0
    # shellcheck source=/dev/null
    source "$STATE_DIR/state" 2>/dev/null || true
    if [[ "${last_run_epoch:-0}" -gt 0 ]]; then
        age_hours=$(( ( $(date +%s) - last_run_epoch ) / 3600 ))
        if [[ $age_hours -gt ${PATCH_GREMLIN_MAX_AGE_HOURS:-49} ]]; then
            log "⚠ Last run was ${age_hours}h ago"
            add_warning
        else
            log "✓ Last run was ${age_hours}h ago (status: ${last_status:-unknown})"
        fi
    fi
fi

log "=== Health Check Summary ==="
log "Warnings: $WARNINGS"
log "Errors: $ERRORS"

if [[ $ERRORS -gt 0 ]]; then
    log "Status: CRITICAL"
    exit 2
elif [[ $WARNINGS -gt 0 ]]; then
    log "Status: WARNING"
    exit 1
fi
log "Status: HEALTHY"
exit 0
