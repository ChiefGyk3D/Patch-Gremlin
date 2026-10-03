#!/bin/bash
#
# Patch Gremlin - configuration diagnostic.
# Human-readable report on how this host is configured and why notifications
# might not be arriving.

set -uo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="${PATCH_GREMLIN_CONFIG_DIR:-/etc/update-notifier}"
NOTIFIER="${PATCH_GREMLIN_NOTIFIER:-/usr/local/bin/update-notifier.sh}"
STATE_DIR="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}"
DROPIN="/etc/systemd/system/update-notifier.service.d/diagnose-dryrun.conf"

usage() {
    cat <<EOF
Patch Gremlin diagnostics v${PATCH_GREMLIN_VERSION}

Usage: sudo ./diagnose-config.sh [--no-test] [--help]

  --no-test   Skip the live dry-run notification test
EOF
}

RUN_TEST=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-test)    RUN_TEST=false ;;
        -h|--help)    usage; exit 0 ;;
        -V|--version) echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# The dry-run test installs a temporary drop-in. Without a trap, a Ctrl-C
# between install and removal left PATCH_GREMLIN_DRY_RUN=true in place - and
# the service then silently stopped sending anything, forever.
cleanup() {
    if [[ -f "$DROPIN" ]]; then
        rm -f "$DROPIN"
        rmdir /etc/systemd/system/update-notifier.service.d 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        echo -e "\n${YELLOW}Cleaned up temporary dry-run override${NC}"
    fi
}
trap cleanup EXIT INT TERM

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}    Patch Gremlin Diagnostic v${PATCH_GREMLIN_VERSION}${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Not running as root - some checks will be skipped.${NC}"
    echo "For the full report: sudo bash $0"
    echo ""
fi

check_mode() {
    local f="$1" expected="$2" label="$3" perms
    perms="$(stat -c '%a' "$f" 2>/dev/null || echo '???')"
    if [[ "$perms" == "$expected" ]]; then
        echo -e "   ${GREEN}✓${NC} $label permissions are $perms"
    else
        echo -e "   ${YELLOW}⚠${NC} $label permissions are $perms (expected $expected)"
        echo -e "       Fix with: ${BLUE}sudo chmod $expected $f${NC}"
    fi
}

echo -e "${YELLOW}1. Secret storage${NC}"
if [[ -f "$CONFIG_DIR/secrets.conf" ]]; then
    echo -e "   ${GREEN}✓${NC} LOCAL mode: $CONFIG_DIR/secrets.conf"
    check_mode "$CONFIG_DIR/secrets.conf" 600 "Secrets file"
    if [[ $EUID -eq 0 ]]; then
        found=0
        for key in DISCORD_WEBHOOK SLACK_WEBHOOK TEAMS_WEBHOOK MATRIX_WEBHOOK \
                   MATRIX_HOMESERVER NTFY_URL GOTIFY_URL GENERIC_WEBHOOK_URL; do
            if grep -qE "^${key}=\"?[^\"[:space:]]+\"?$" "$CONFIG_DIR/secrets.conf" 2>/dev/null; then
                echo -e "   ${GREEN}✓${NC} ${key%%_*} configured"
                found=$((found + 1))
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo -e "   ${RED}✗${NC} No endpoint has a value set"
            echo -e "       ${YELLOW}Action:${NC} edit $CONFIG_DIR/secrets.conf"
        fi
    fi
elif [[ -f "$CONFIG_DIR/env" ]]; then
    echo -e "   ${GREEN}✓${NC} Environment file: $CONFIG_DIR/env"
    check_mode "$CONFIG_DIR/env" 600 "Environment file"
    if grep -q '^SECRET_MODE=doppler' "$CONFIG_DIR/env" 2>/dev/null; then
        echo -e "   ${GREEN}✓${NC} DOPPLER mode"
        if command -v doppler &>/dev/null; then
            echo -e "   ${GREEN}✓${NC} Doppler CLI installed"
        else
            echo -e "   ${YELLOW}⚠${NC} Doppler CLI not installed"
        fi
    fi
else
    echo -e "   ${RED}✗${NC} No secret storage found in $CONFIG_DIR"
    echo -e "       ${YELLOW}Action:${NC} re-run sudo -E ./setup-unattended-upgrades.sh"
fi

echo ""
echo -e "${YELLOW}2. Notification script${NC}"
if [[ -x "$NOTIFIER" ]]; then
    echo -e "   ${GREEN}✓${NC} $NOTIFIER is present and executable"
    echo -e "   ${BLUE}$("$NOTIFIER" --version 2>/dev/null || echo 'version unknown')${NC}"
else
    echo -e "   ${RED}✗${NC} $NOTIFIER missing or not executable"
fi

echo ""
echo -e "${YELLOW}3. Trigger wiring${NC}"
for unit in apt-daily-upgrade dnf-automatic; do
    dropin="/etc/systemd/system/${unit}.service.d/patch-gremlin.conf"
    if [[ -f "$dropin" ]]; then
        echo -e "   ${GREEN}✓${NC} Hooked onto ${unit}.service"
    fi
done
if [[ -f /etc/apt/apt.conf.d/99patch-gremlin-notification ]]; then
    echo -e "   ${YELLOW}⚠${NC} Legacy APT Dpkg::Post-Invoke hook still present"
    echo -e "       It fires after EVERY apt command. Re-run setup to remove it."
fi
if systemctl is-enabled update-notifier.timer &>/dev/null; then
    echo -e "   ${GREEN}✓${NC} Heartbeat timer enabled"
    systemctl list-timers update-notifier.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/       /'
else
    echo -e "   ${BLUE}·${NC} Heartbeat timer disabled (notifications are upgrade-driven)"
fi

echo ""
echo -e "${YELLOW}4. Last run${NC}"
if [[ -r "$STATE_DIR/state" ]]; then
    sed 's/^/   /' "$STATE_DIR/state"
else
    echo -e "   ${BLUE}·${NC} No state recorded yet at $STATE_DIR/state"
fi

echo ""
echo -e "${YELLOW}5. Recent log entries${NC}"
if command -v journalctl &>/dev/null; then
    journalctl -t patch-gremlin -n 10 --no-pager 2>/dev/null | sed 's/^/   /' \
        || echo "   (none found)"
else
    echo "   journalctl not available"
fi

echo ""
echo -e "${YELLOW}6. Live dry-run test${NC}"
if [[ "$RUN_TEST" != "true" ]]; then
    echo "   Skipped (--no-test)"
elif [[ $EUID -ne 0 ]]; then
    echo "   Skipped (run as root to test)"
elif [[ ! -x "$NOTIFIER" ]]; then
    echo "   Skipped (notifier not installed)"
else
    mkdir -p /etc/systemd/system/update-notifier.service.d
    printf '[Service]\nEnvironment="PATCH_GREMLIN_DRY_RUN=true"\n' > "$DROPIN"
    systemctl daemon-reload
    if systemctl start update-notifier.service 2>&1; then
        exitcode="$(systemctl show update-notifier.service --property=ExecMainStatus --value)"
    else
        exitcode=1
    fi
    journalctl -u update-notifier.service -n 20 --no-pager --since "1 minute ago" 2>/dev/null \
        | grep -v '^--' | sed 's/^/   /'
    if [[ "$exitcode" == "0" ]]; then
        echo -e "   ${GREEN}✓${NC} Dry run completed successfully"
    else
        echo -e "   ${RED}✗${NC} Dry run exited with code $exitcode"
    fi
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "Common fixes:"
echo -e "  ${YELLOW}Empty local secrets${NC}   sudo nano $CONFIG_DIR/secrets.conf"
echo -e "  ${YELLOW}Doppler CLI missing${NC}   curl -sLf https://cli.doppler.com/install.sh | sh"
echo -e "  ${YELLOW}Nothing configured${NC}    sudo -E ./setup-unattended-upgrades.sh"
echo -e "  ${YELLOW}Legacy APT hook${NC}       sudo -E ./setup-unattended-upgrades.sh --update-only"
