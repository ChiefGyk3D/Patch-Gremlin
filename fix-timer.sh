#!/bin/bash
# Quick fix to enable and start the update-notifier.timer
# Run this on systems where setup was run before the timer activation was added

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    echo "Run: sudo bash $0"
    exit 1
fi

echo -e "${YELLOW}Fixing update-notifier.timer activation...${NC}"
echo ""

# Check if timer exists
if [[ ! -f /etc/systemd/system/update-notifier.timer ]]; then
    echo -e "${RED}Error: Timer not found. Run setup script first.${NC}"
    exit 1
fi

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable timer
echo "Enabling update-notifier.timer..."
systemctl enable update-notifier.timer

# Start timer
echo "Starting update-notifier.timer..."
systemctl start update-notifier.timer

echo ""
echo -e "${GREEN}✓ Timer activated successfully!${NC}"
echo ""

# Show status
echo "Current status:"
systemctl status update-notifier.timer --no-pager -l

echo ""
echo "Next scheduled run:"
systemctl list-timers update-notifier.timer --no-pager

echo ""
echo -e "${GREEN}Done! Your notification timer is now active.${NC}"
