#!/bin/bash

# Patch Gremlin - Fix Verbose Logging
# Disables debug/verbose output from unattended-upgrades
# Run this to clean up your systemd logs

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   echo "Please run: sudo $0"
   exit 1
fi

echo -e "${YELLOW}Fixing verbose logging in unattended-upgrades...${NC}"
echo ""

# Backup existing configs
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    cp /etc/apt/apt.conf.d/50unattended-upgrades \
       "/etc/apt/apt.conf.d/50unattended-upgrades.backup.$(date +%Y%m%d-%H%M%S)"
    echo -e "${GREEN}✓${NC} Backed up 50unattended-upgrades"
fi

if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    cp /etc/apt/apt.conf.d/20auto-upgrades \
       "/etc/apt/apt.conf.d/20auto-upgrades.backup.$(date +%Y%m%d-%H%M%S)"
    echo -e "${GREEN}✓${NC} Backed up 20auto-upgrades"
fi

# Fix verbose setting in 50unattended-upgrades
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    if grep -q 'Unattended-Upgrade::Verbose "true"' /etc/apt/apt.conf.d/50unattended-upgrades; then
        sed -i 's/Unattended-Upgrade::Verbose "true"/Unattended-Upgrade::Verbose "false"/' \
            /etc/apt/apt.conf.d/50unattended-upgrades
        echo -e "${GREEN}✓${NC} Disabled verbose logging in 50unattended-upgrades"
    else
        echo -e "${YELLOW}⚠${NC} Verbose already disabled in 50unattended-upgrades"
    fi
else
    echo -e "${RED}✗${NC} /etc/apt/apt.conf.d/50unattended-upgrades not found"
fi

# Fix verbose setting in 20auto-upgrades
if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    if grep -q 'APT::Periodic::Verbose "2"' /etc/apt/apt.conf.d/20auto-upgrades; then
        sed -i 's/APT::Periodic::Verbose "2"/APT::Periodic::Verbose "0"/' \
            /etc/apt/apt.conf.d/20auto-upgrades
        echo -e "${GREEN}✓${NC} Disabled verbose logging in 20auto-upgrades"
    elif grep -q 'APT::Periodic::Verbose "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
        sed -i 's/APT::Periodic::Verbose "1"/APT::Periodic::Verbose "0"/' \
            /etc/apt/apt.conf.d/20auto-upgrades
        echo -e "${GREEN}✓${NC} Disabled verbose logging in 20auto-upgrades"
    else
        echo -e "${YELLOW}⚠${NC} Verbose already disabled in 20auto-upgrades"
    fi
else
    echo -e "${RED}✗${NC} /etc/apt/apt.conf.d/20auto-upgrades not found"
fi

echo ""
echo -e "${GREEN}Logging fix complete!${NC}"
echo ""
echo "The next time unattended-upgrades runs, you'll see much cleaner logs."
echo ""
echo -e "${YELLOW}What changed:${NC}"
echo "• Unattended-Upgrade::Verbose: true → false"
echo "• APT::Periodic::Verbose: 2 → 0"
echo ""
echo "You'll still see important messages like:"
echo "  - When updates are installed"
echo "  - If any errors occur"
echo "  - Summary of changes"
echo ""
echo "But you won't see the detailed DEBUG output anymore."
