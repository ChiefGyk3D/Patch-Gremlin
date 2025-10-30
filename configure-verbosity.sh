#!/bin/bash

# Patch Gremlin - Configure Verbose Logging
# Enable or disable debug/verbose output from unattended-upgrades
# Run this to adjust logging verbosity

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   echo "Please run: sudo $0"
   exit 1
fi

echo -e "${YELLOW}Configure Verbose Logging${NC}"
echo ""
echo "Current verbose logging status:"

# Check current settings
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    if grep -q 'Unattended-Upgrade::Verbose "true"' /etc/apt/apt.conf.d/50unattended-upgrades; then
        echo -e "  50unattended-upgrades: ${GREEN}ENABLED${NC}"
        CURRENT_50="true"
    else
        echo -e "  50unattended-upgrades: ${BLUE}DISABLED${NC}"
        CURRENT_50="false"
    fi
else
    echo -e "  ${RED}50unattended-upgrades not found${NC}"
    CURRENT_50="unknown"
fi

if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    VERBOSE_VAL=$(grep 'APT::Periodic::Verbose' /etc/apt/apt.conf.d/20auto-upgrades | grep -oP '\d+' || echo "0")
    if [[ "$VERBOSE_VAL" == "0" ]]; then
        echo -e "  20auto-upgrades: ${BLUE}DISABLED${NC} (Verbose: $VERBOSE_VAL)"
        CURRENT_20="false"
    else
        echo -e "  20auto-upgrades: ${GREEN}ENABLED${NC} (Verbose: $VERBOSE_VAL)"
        CURRENT_20="true"
    fi
else
    echo -e "  ${RED}20auto-upgrades not found${NC}"
    CURRENT_20="unknown"
fi

echo ""
echo "What would you like to do?"
echo "  1) Disable verbose logging (quiet - recommended)"
echo "  2) Enable verbose logging (debug)"
echo "  3) Cancel"
echo ""
read -p "Enter choice [1-3] (default: 1): " -n 1 -r CHOICE
echo ""
echo ""

case "$CHOICE" in
    2)
        TARGET_VERBOSE="true"
        TARGET_PERIODIC="2"
        ACTION="Enabling"
        ;;
    3)
        echo "Cancelled."
        exit 0
        ;;
    *)
        TARGET_VERBOSE="false"
        TARGET_PERIODIC="0"
        ACTION="Disabling"
        ;;
esac

echo -e "${YELLOW}${ACTION} verbose logging...${NC}"
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

# Update 50unattended-upgrades
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    if grep -q 'Unattended-Upgrade::Verbose' /etc/apt/apt.conf.d/50unattended-upgrades; then
        sed -i "s/Unattended-Upgrade::Verbose \".*\"/Unattended-Upgrade::Verbose \"$TARGET_VERBOSE\"/" \
            /etc/apt/apt.conf.d/50unattended-upgrades
        echo -e "${GREEN}✓${NC} Updated 50unattended-upgrades: Verbose=$TARGET_VERBOSE"
    else
        echo -e "${YELLOW}⚠${NC} Verbose setting not found in 50unattended-upgrades"
    fi
else
    echo -e "${RED}✗${NC} /etc/apt/apt.conf.d/50unattended-upgrades not found"
fi

# Update 20auto-upgrades
if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    if grep -q 'APT::Periodic::Verbose' /etc/apt/apt.conf.d/20auto-upgrades; then
        sed -i "s/APT::Periodic::Verbose \"[0-9]\"/APT::Periodic::Verbose \"$TARGET_PERIODIC\"/" \
            /etc/apt/apt.conf.d/20auto-upgrades
        echo -e "${GREEN}✓${NC} Updated 20auto-upgrades: Verbose=$TARGET_PERIODIC"
    else
        echo -e "${YELLOW}⚠${NC} Verbose setting not found in 20auto-upgrades"
    fi
else
    echo -e "${RED}✗${NC} /etc/apt/apt.conf.d/20auto-upgrades not found"
fi

echo ""
echo -e "${GREEN}Configuration complete!${NC}"
echo ""

if [[ "$TARGET_VERBOSE" == "false" ]]; then
    echo "Verbose logging is now DISABLED."
    echo ""
    echo "You'll see important messages like:"
    echo "  - When updates are installed"
    echo "  - If any errors occur"
    echo "  - Summary of changes"
    echo ""
    echo "But you won't see detailed DEBUG output."
else
    echo "Verbose logging is now ENABLED."
    echo ""
    echo "You'll see detailed DEBUG output including:"
    echo "  - Package checking details"
    echo "  - Origin pattern matching"
    echo "  - Candidate version adjustments"
    echo ""
    echo "This is useful for troubleshooting but creates large logs."
fi

echo ""
echo "Changes will take effect on the next unattended-upgrades run."
