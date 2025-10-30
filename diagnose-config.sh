#!/bin/bash
# Diagnostic script to check Patch Gremlin configuration

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}    Patch Gremlin Configuration Diagnostic${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script should be run as root to see all config${NC}"
    echo "Run: sudo bash $0"
    echo ""
    echo "Continuing with limited info..."
    echo ""
fi

# Check secrets file
echo -e "${YELLOW}1. Checking for Local Secrets File:${NC}"
if [[ -f /etc/update-notifier/secrets.conf ]]; then
    echo -e "   ${GREEN}✓${NC} Found: /etc/update-notifier/secrets.conf"
    perms=$(stat -c "%a" /etc/update-notifier/secrets.conf 2>/dev/null)
    echo "   Permissions: $perms"
    if [[ "$perms" == "600" ]]; then
        echo -e "   ${GREEN}✓${NC} Permissions are secure"
    else
        echo -e "   ${YELLOW}⚠${NC} Permissions should be 600"
    fi
    
    if [[ $EUID -eq 0 ]]; then
        echo ""
        echo "   Configured webhooks (values masked):"
        if grep -q "^DISCORD_WEBHOOK=" /etc/update-notifier/secrets.conf 2>/dev/null; then
            echo -e "   ${GREEN}✓${NC} Discord webhook configured"
        fi
        if grep -q "^TEAMS_WEBHOOK=" /etc/update-notifier/secrets.conf 2>/dev/null; then
            echo -e "   ${GREEN}✓${NC} Teams webhook configured"
        fi
        if grep -q "^SLACK_WEBHOOK=" /etc/update-notifier/secrets.conf 2>/dev/null; then
            echo -e "   ${GREEN}✓${NC} Slack webhook configured"
        fi
        if grep -q "^MATRIX_WEBHOOK=" /etc/update-notifier/secrets.conf 2>/dev/null; then
            echo -e "   ${GREEN}✓${NC} Matrix webhook configured"
        fi
        if grep -q "^MATRIX_HOMESERVER=" /etc/update-notifier/secrets.conf 2>/dev/null; then
            echo -e "   ${GREEN}✓${NC} Matrix API configured"
        fi
        
        # Check if any are actually empty
        has_config=false
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            if [[ "$key" =~ ^(DISCORD_WEBHOOK|TEAMS_WEBHOOK|SLACK_WEBHOOK|MATRIX_WEBHOOK|MATRIX_HOMESERVER)$ ]]; then
                if [[ -n "$value" ]] && [[ "$value" != '""' ]] && [[ "$value" != "''" ]]; then
                    has_config=true
                    break
                fi
            fi
        done < /etc/update-notifier/secrets.conf
        
        if [[ "$has_config" == "false" ]]; then
            echo -e "   ${RED}✗${NC} No webhooks have values configured!"
            echo "   ${YELLOW}Action needed:${NC} Edit /etc/update-notifier/secrets.conf and add webhook URLs"
        fi
    fi
else
    echo -e "   ${YELLOW}✗${NC} Not found: /etc/update-notifier/secrets.conf"
    echo "   This means you're using Doppler mode (or setup didn't complete)"
fi

echo ""
echo -e "${YELLOW}2. Checking Systemd Service Environment:${NC}"
if systemctl show update-notifier.service | grep -q "SECRET_MODE=local"; then
    echo -e "   ${GREEN}✓${NC} Service configured for LOCAL mode"
elif systemctl show update-notifier.service | grep -q "DOPPLER_TOKEN="; then
    echo -e "   ${GREEN}✓${NC} Service configured for DOPPLER mode"
    if command -v doppler &>/dev/null; then
        echo -e "   ${GREEN}✓${NC} Doppler CLI is installed"
    else
        echo -e "   ${RED}✗${NC} Doppler CLI is NOT installed"
    fi
else
    echo -e "   ${RED}✗${NC} Service has no SECRET_MODE or DOPPLER_TOKEN configured"
    echo "   This will cause notifications to fail"
fi

echo ""
echo -e "${YELLOW}3. Checking Update Notifier Script:${NC}"
if [[ -f /usr/local/bin/update-notifier.sh ]]; then
    echo -e "   ${GREEN}✓${NC} Script exists"
    if [[ -x /usr/local/bin/update-notifier.sh ]]; then
        echo -e "   ${GREEN}✓${NC} Script is executable"
    else
        echo -e "   ${RED}✗${NC} Script is not executable"
    fi
else
    echo -e "   ${RED}✗${NC} Script not found"
fi

echo ""
echo -e "${YELLOW}4. Recent Log Messages:${NC}"
if command -v journalctl &>/dev/null; then
    echo "   Last 5 patch-gremlin log entries:"
    journalctl -t patch-gremlin -n 5 --no-pager 2>/dev/null | sed 's/^/   /' || echo "   (none found)"
else
    echo "   journalctl not available"
fi

echo ""
echo -e "${YELLOW}5. Testing Notification (dry run):${NC}"
if [[ $EUID -eq 0 ]]; then
    echo "   Running: /usr/local/bin/update-notifier.sh 2>&1 | head -30"
    echo "   ---"
    PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh 2>&1 | head -30 | sed 's/^/   /'
    exitcode=${PIPESTATUS[0]}
    echo "   ---"
    if [[ $exitcode -eq 0 ]]; then
        echo -e "   ${GREEN}✓${NC} Script completed successfully"
    else
        echo -e "   ${RED}✗${NC} Script exited with code: $exitcode"
    fi
else
    echo "   Skipped (run as root to test)"
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}    Diagnostic Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Common Issues:"
echo ""
echo "1. ${YELLOW}If using LOCAL mode but secrets file is empty:${NC}"
echo "   → Edit: sudo nano /etc/update-notifier/secrets.conf"
echo "   → Add your webhook URLs"
echo ""
echo "2. ${YELLOW}If using DOPPLER mode but CLI not installed:${NC}"
echo "   → Install Doppler: curl -sLf https://cli.doppler.com/install.sh | sh"
echo "   → Configure: doppler login && doppler setup"
echo ""
echo "3. ${YELLOW}If service not configured:${NC}"
echo "   → Re-run setup: sudo -E bash setup-unattended-upgrades.sh"
echo ""
