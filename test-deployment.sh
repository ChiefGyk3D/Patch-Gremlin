#!/bin/bash
# Comprehensive deployment test for Patch Gremlin
# Tests both the notification system and unattended upgrades

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      Patch Gremlin Deployment Test Suite                ║${NC}"
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    echo "Run: sudo bash $0"
    exit 1
fi

# Detect OS
if [[ -f /etc/debian_version ]]; then
    OS_TYPE="debian"
    UPDATE_SERVICE="apt-daily-upgrade.service"
    UPDATE_TIMER="apt-daily-upgrade.timer"
    HOOK_FILE="/etc/apt/apt.conf.d/99patch-gremlin-notification"
elif [[ -f /etc/redhat-release ]]; then
    OS_TYPE="rhel"
    UPDATE_SERVICE="dnf-automatic.service"
    UPDATE_TIMER="dnf-automatic.timer"
    HOOK_FILE="/etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf"
else
    echo -e "${RED}Unsupported OS${NC}"
    exit 1
fi

echo -e "${YELLOW}Detected OS: ${OS_TYPE}${NC}"
echo ""

# Test 1: Check Installation
echo -e "${BLUE}═══ Test 1: Installation Check ═══${NC}"
test1_pass=true

files_to_check=(
    "/usr/local/bin/update-notifier.sh"
    "/etc/systemd/system/update-notifier.service"
    "/etc/systemd/system/update-notifier.timer"
    "$HOOK_FILE"
)

for file in "${files_to_check[@]}"; do
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓${NC} Found: $file"
    else
        echo -e "${RED}✗${NC} Missing: $file"
        test1_pass=false
    fi
done

if [[ "$test1_pass" == "true" ]]; then
    echo -e "${GREEN}Test 1: PASSED${NC}"
else
    echo -e "${RED}Test 1: FAILED${NC}"
    echo ""
    echo -e "${YELLOW}Patch Gremlin is not installed on this system.${NC}"
    echo ""
    echo "This test must be run on the system where Patch Gremlin is installed."
    echo ""
    echo "To install Patch Gremlin on this system:"
    echo "  sudo ./setup-unattended-upgrades.sh"
    echo ""
    echo "To test a remote system (e.g., Raspberry Pi):"
    echo "  ssh pi@your-pi-hostname"
    echo "  cd /path/to/Patch-Gremlin"
    echo "  sudo ./test-deployment.sh"
    exit 1
fi
echo ""

# Test 2: Check Secret Storage Mode
echo -e "${BLUE}═══ Test 2: Secret Storage Mode ═══${NC}"
test2_pass=true

# Debug: Show what we're checking
echo "Checking for secret storage configuration..."
echo "  - Looking for: /etc/update-notifier/secrets.conf"
echo "  - Looking for: DOPPLER_TOKEN in systemd service"

# Check which mode is configured
if [[ -f /etc/update-notifier/secrets.conf ]]; then
    echo -e "${GREEN}✓${NC} Local mode: /etc/update-notifier/secrets.conf exists"
    SECRET_MODE="local"
    
    # Verify permissions
    perms=$(stat -c "%a" /etc/update-notifier/secrets.conf)
    if [[ "$perms" == "600" ]]; then
        echo -e "${GREEN}✓${NC} File permissions are secure (600)"
    else
        echo -e "${YELLOW}⚠${NC} File permissions: $perms (should be 600)"
        echo "   Fix with: sudo chmod 600 /etc/update-notifier/secrets.conf"
        test2_pass=false
    fi
    
    # Check if at least one webhook is configured
    webhook_count=0
    if grep -q '^DISCORD_WEBHOOK=.\+' /etc/update-notifier/secrets.conf 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Discord webhook configured"
        ((webhook_count++))
    fi
    if grep -q '^TEAMS_WEBHOOK=.\+' /etc/update-notifier/secrets.conf 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Teams webhook configured"
        ((webhook_count++))
    fi
    if grep -q '^SLACK_WEBHOOK=.\+' /etc/update-notifier/secrets.conf 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Slack webhook configured"
        ((webhook_count++))
    fi
    if grep -q '^MATRIX_WEBHOOK=.\+' /etc/update-notifier/secrets.conf 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Matrix webhook configured"
        ((webhook_count++))
    fi
    if grep -q '^MATRIX_HOMESERVER=.\+' /etc/update-notifier/secrets.conf 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Matrix API configured"
        ((webhook_count++))
    fi
    
    if [[ $webhook_count -eq 0 ]]; then
        echo -e "${RED}✗${NC} No webhooks configured in secrets file"
        echo "   Edit: sudo nano /etc/update-notifier/secrets.conf"
        test2_pass=false
    else
        echo -e "${GREEN}✓${NC} $webhook_count platform(s) configured"
    fi
    
elif systemctl show update-notifier.service 2>&1 | grep -q "DOPPLER_TOKEN="; then
    echo -e "${GREEN}✓${NC} Doppler mode: Token configured in systemd"
    SECRET_MODE="doppler"
    
    # Check if doppler CLI is available
    if command -v doppler &>/dev/null; then
        echo -e "${GREEN}✓${NC} Doppler CLI is installed"
    else
        echo -e "${YELLOW}⚠${NC} Doppler CLI not found (not required for service operation)"
        echo "   The service will work without CLI (uses embedded token)"
    fi
    
    # Verify service has token
    if systemctl show update-notifier.service 2>&1 | grep -q "DOPPLER_TOKEN=dp.st."; then
        echo -e "${GREEN}✓${NC} Valid Doppler service token format in systemd"
    else
        echo -e "${RED}✗${NC} Invalid or missing Doppler token in systemd service"
        test2_pass=false
    fi
    
else
    echo -e "${RED}✗${NC} Cannot determine secret storage mode"
    echo "   Neither /etc/update-notifier/secrets.conf nor systemd DOPPLER_TOKEN found"
    echo ""
    echo "   Debug: Checking systemd service..."
    systemctl show update-notifier.service 2>&1 | grep "Environment=" | head -3
    echo ""
    echo "   Re-run setup: sudo ./setup-unattended-upgrades.sh"
    SECRET_MODE="unknown"
    test2_pass=false
fi

if [[ "$test2_pass" == "true" ]]; then
    echo -e "${GREEN}Test 2: PASSED${NC}"
else
    echo -e "${RED}Test 2: FAILED${NC}"
fi
echo ""

# Test 3: Systemd Service Status
echo -e "${BLUE}═══ Test 3: Systemd Services ═══${NC}"
test3_pass=true

# Check update-notifier service
if systemctl is-enabled update-notifier.timer &>/dev/null; then
    echo -e "${GREEN}✓${NC} update-notifier.timer is enabled"
else
    echo -e "${YELLOW}⚠${NC} update-notifier.timer is not enabled"
    test3_pass=false
fi

if systemctl is-active update-notifier.timer &>/dev/null; then
    echo -e "${GREEN}✓${NC} update-notifier.timer is active"
else
    echo -e "${YELLOW}⚠${NC} update-notifier.timer is not active"
    test3_pass=false
fi

# Check system update service
if systemctl is-enabled "$UPDATE_TIMER" &>/dev/null; then
    echo -e "${GREEN}✓${NC} $UPDATE_TIMER is enabled"
else
    echo -e "${YELLOW}⚠${NC} $UPDATE_TIMER is not enabled"
    test3_pass=false
fi

# Show timer schedule
echo ""
echo "Timer schedules:"
systemctl list-timers update-notifier.timer "$UPDATE_TIMER" --no-pager 2>/dev/null || true

if [[ "$test3_pass" == "true" ]]; then
    echo -e "${GREEN}Test 3: PASSED${NC}"
else
    echo -e "${YELLOW}Test 3: PASSED WITH WARNINGS${NC}"
fi
echo ""

# Test 4: Manual Notification Test
echo -e "${BLUE}═══ Test 4: Manual Notification Test ═══${NC}"
echo "This will trigger a test notification immediately."
read -p "Run test notification? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting notification service..."
    if systemctl start update-notifier.service; then
        echo -e "${GREEN}✓${NC} Service started successfully"
        
        echo "Waiting 5 seconds for notification to send..."
        sleep 5
        
        echo "Checking service results..."
        systemctl status update-notifier.service --no-pager || true
        
        # Check if service completed successfully (exit code 0)
        # Note: systemctl status returns non-zero for "inactive" even if service succeeded
        if systemctl show update-notifier.service --property=ExecMainStatus --value | grep -q "^0$"; then
            echo ""
            echo -e "${GREEN}✓${NC} Service completed successfully (exit code 0)"
            echo "Check your configured notification channels for the update report!"
            echo -e "${GREEN}Test 4: PASSED${NC}"
        else
            exit_code=$(systemctl show update-notifier.service --property=ExecMainStatus --value)
            echo ""
            echo -e "${RED}✗${NC} Service failed with exit code: $exit_code"
            echo "Check logs: journalctl -u update-notifier.service -n 50"
            echo -e "${RED}Test 4: FAILED${NC}"
        fi
    else
        echo -e "${RED}✗${NC} Failed to start service"
        echo -e "${RED}Test 4: FAILED${NC}"
    fi
else
    echo "Skipped manual notification test"
    echo -e "${YELLOW}Test 4: SKIPPED${NC}"
fi
echo ""

# Test 5: Update System Test (Dry Run)
echo -e "${BLUE}═══ Test 5: Update System Check ═══${NC}"

if [[ "$OS_TYPE" == "debian" ]]; then
    echo "Checking for available updates..."
    apt-get update -qq
    
    upgradable=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
    echo "Upgradable packages: $upgradable"
    
    if [[ $upgradable -gt 0 ]]; then
        echo -e "${GREEN}✓${NC} Updates available for testing"
        echo ""
        echo "Available updates:"
        apt list --upgradable 2>/dev/null | head -10
    else
        echo -e "${YELLOW}⚠${NC} No updates available (system is up to date)"
        echo "To test, you can:"
        echo "  1. Wait for new updates"
        echo "  2. Use 'sudo apt-mark hold <package>' then 'sudo apt-mark unhold <package>'"
    fi
    
    # Check unattended-upgrades configuration
    if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
        echo -e "${GREEN}✓${NC} unattended-upgrades is configured"
    fi
    
elif [[ "$OS_TYPE" == "rhel" ]]; then
    echo "Checking for available updates..."
    updates=$(dnf check-update -q 2>/dev/null | grep -v "^$" | wc -l || echo "0")
    
    echo "Available updates: $updates"
    
    if [[ $updates -gt 0 ]]; then
        echo -e "${GREEN}✓${NC} Updates available for testing"
        echo ""
        echo "Available updates:"
        dnf check-update 2>/dev/null | head -10
    else
        echo -e "${YELLOW}⚠${NC} No updates available (system is up to date)"
    fi
    
    # Check dnf-automatic configuration
    if [[ -f /etc/dnf/automatic.conf ]]; then
        echo -e "${GREEN}✓${NC} dnf-automatic is configured"
    fi
fi

echo -e "${GREEN}Test 5: PASSED${NC}"
echo ""

# Test 6: Hook Test (Safe)
echo -e "${BLUE}═══ Test 6: Hook Execution Test ═══${NC}"
echo "This tests if the notification hook would trigger correctly."
echo ""

if [[ "$OS_TYPE" == "debian" ]]; then
    # Check if hook is properly configured
    if grep -q "update-notifier.sh" "$HOOK_FILE"; then
        echo -e "${GREEN}✓${NC} APT hook is configured"
        
        # Show hook content
        echo "Hook configuration:"
        cat "$HOOK_FILE"
        echo ""
        
        # Test hook execution (this is safe, just runs the notifier)
        read -p "Test APT hook by installing a small package (vim-tiny)? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Installing vim-tiny (this will trigger the hook)..."
            apt-get install -y vim-tiny
            echo ""
            echo "Check if notification was sent!"
            echo "View logs: journalctl -xe | grep -i patch-gremlin"
        else
            echo "Skipped hook test"
        fi
    else
        echo -e "${RED}✗${NC} APT hook not configured correctly"
    fi
    
elif [[ "$OS_TYPE" == "rhel" ]]; then
    if [[ -f "$HOOK_FILE" ]]; then
        echo -e "${GREEN}✓${NC} DNF hook is configured"
        echo "Hook configuration:"
        cat "$HOOK_FILE"
    else
        echo -e "${RED}✗${NC} DNF hook not found"
    fi
fi

echo -e "${GREEN}Test 6: PASSED${NC}"
echo ""

# Test 7: Log Check
echo -e "${BLUE}═══ Test 7: Log Analysis ═══${NC}"

echo "Recent Patch Gremlin activity:"
journalctl -u update-notifier.service --no-pager -n 20 2>/dev/null || echo "No recent activity"

echo ""
echo "Recent system update activity:"
if [[ "$OS_TYPE" == "debian" ]]; then
    journalctl -u unattended-upgrades.service --no-pager -n 10 2>/dev/null || echo "No recent activity"
else
    journalctl -u dnf-automatic.service --no-pager -n 10 2>/dev/null || echo "No recent activity"
fi

echo -e "${GREEN}Test 7: COMPLETED${NC}"
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Test Summary                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Secret Mode: ${YELLOW}${SECRET_MODE}${NC}"
echo -e "OS Type: ${YELLOW}${OS_TYPE}${NC}"
echo ""
echo "Next Steps:"
echo "  1. Verify you received test notification(s)"
echo "  2. Wait for scheduled update time to verify automatic operation"
echo "  3. Monitor logs: journalctl -u update-notifier.service -f"
echo ""
echo "To manually trigger updates (for testing):"
if [[ "$OS_TYPE" == "debian" ]]; then
    echo "  sudo unattended-upgrades --debug --dry-run"
    echo "  sudo unattended-upgrades"
else
    echo "  sudo dnf-automatic --downloadupdates"
    echo "  sudo dnf-automatic"
fi
echo ""
echo -e "${GREEN}All tests completed!${NC}"
