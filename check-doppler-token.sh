#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Doppler Token Diagnostic ==="
echo ""

# Check systemd service environment
echo "1. Checking systemd service environment:"
echo ""
if systemctl show update-notifier.service -p Environment | grep -q "DOPPLER_TOKEN="; then
    echo -e "   ${GREEN}✓${NC} DOPPLER_TOKEN is set in systemd service"
    echo "   (Token is embedded in the service, good!)"
else
    echo -e "   ${RED}✗${NC} DOPPLER_TOKEN not found in systemd service"
fi

echo ""
echo "2. Checking current shell environment:"
echo ""
if [[ -n "${DOPPLER_TOKEN:-}" ]]; then
    echo -e "   ${GREEN}✓${NC} DOPPLER_TOKEN is set in current environment"
else
    echo -e "   ${YELLOW}⚠${NC} DOPPLER_TOKEN is NOT set in current environment"
    echo "   This is why manual runs fail!"
fi

echo ""
echo "3. Checking Doppler CLI authentication:"
echo ""
if command -v doppler &>/dev/null; then
    if doppler me &>/dev/null; then
        echo -e "   ${GREEN}✓${NC} Doppler CLI is authenticated"
        echo "   Authenticated as: $(doppler me --json 2>/dev/null | grep -o '"workplace":{"name":"[^"]*"' | cut -d'"' -f6)"
    else
        echo -e "   ${RED}✗${NC} Doppler CLI is NOT authenticated"
        echo "   This is likely the issue!"
    fi
else
    echo -e "   ${RED}✗${NC} Doppler CLI not found"
fi

echo ""
echo "=== Why Manual Run Fails ==="
echo ""
echo "When you run: sudo /usr/local/bin/update-notifier.sh"
echo ""
echo "The script looks for DOPPLER_TOKEN in the environment, but:"
echo "• The token is stored IN the systemd service file"
echo "• Your current shell doesn't have it"
echo "• Doppler CLI isn't authenticated for manual use"
echo ""
echo "=== Solutions ==="
echo ""
echo "Option 1: Run via systemd (recommended):"
echo "   ${GREEN}sudo systemctl start update-notifier.service${NC}"
echo ""
echo "Option 2: Set DOPPLER_TOKEN manually:"
echo "   ${GREEN}export DOPPLER_TOKEN='dp.st.your-token-here'${NC}"
echo "   ${GREEN}sudo -E /usr/local/bin/update-notifier.sh${NC}"
echo ""
echo "Option 3: Use Doppler CLI authentication:"
echo "   ${GREEN}sudo doppler login${NC}"
echo "   ${GREEN}sudo doppler setup${NC}"
echo "   ${GREEN}sudo /usr/local/bin/update-notifier.sh${NC}"
echo ""
echo "=== Testing with systemd (should work) ==="
read -p "Start notification via systemd now? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting service..."
    systemctl start update-notifier.service
    sleep 2
    echo ""
    echo "Service status:"
    systemctl status update-notifier.service --no-pager -l
    echo ""
    echo "Recent logs:"
    journalctl -u update-notifier.service -n 10 --no-pager
fi

