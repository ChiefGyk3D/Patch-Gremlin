#!/bin/bash

# Patch Gremlin Health Check
# Quick validation of system configuration and connectivity
# Exit codes: 0=healthy, 1=warning, 2=critical

set -euo pipefail

WARNINGS=0
ERRORS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

check_file() {
    local file="$1" desc="$2"
    if [[ -f "$file" ]]; then
        log "✓ $desc exists: $file"
    else
        log "✗ $desc missing: $file"
        ((ERRORS++))
    fi
}

check_service() {
    local service="$1"
    if systemctl is-active "$service" &>/dev/null; then
        log "✓ Service active: $service"
    else
        log "⚠ Service inactive: $service"
        ((WARNINGS++))
    fi
}

log "=== Patch Gremlin Health Check ==="

# Check core files
check_file "/usr/local/bin/update-notifier.sh" "Notification script"
check_file "/etc/systemd/system/update-notifier.service" "Systemd service"
check_file "/etc/systemd/system/update-notifier.timer" "Systemd timer"

# Check timer status
check_service "update-notifier.timer"

# Check Doppler if configured
if [[ -f /etc/update-notifier/config.sh ]]; then
    log "✓ Config file exists"
    if command -v doppler &>/dev/null; then
        if doppler me &>/dev/null; then
            log "✓ Doppler authenticated"
        else
            log "✗ Doppler authentication failed"
            ((ERRORS++))
        fi
    else
        log "⚠ Doppler CLI not found"
        ((WARNINGS++))
    fi
fi

# Test notification (dry run)
log "Testing notification script..."
if PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh &>/dev/null; then
    log "✓ Notification script test passed"
else
    log "✗ Notification script test failed"
    ((ERRORS++))
fi

# Summary
log "=== Health Check Summary ==="
log "Warnings: $WARNINGS"
log "Errors: $ERRORS"

if [[ $ERRORS -gt 0 ]]; then
    log "Status: CRITICAL"
    exit 2
elif [[ $WARNINGS -gt 0 ]]; then
    log "Status: WARNING"
    exit 1
else
    log "Status: HEALTHY"
    exit 0
fi
