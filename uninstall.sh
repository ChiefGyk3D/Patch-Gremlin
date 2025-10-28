#!/bin/bash

# Patch Gremlin - Uninstall Script
# Removes all installed components
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}=== Update Notifier Uninstall ===${NC}\n"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   echo "Please run: sudo $0"
   exit 1
fi

echo -e "${YELLOW}This will remove:${NC}"
echo "  - Notification script (/usr/local/bin/update-notifier.sh)"
echo "  - APT/DNF hooks"
echo "  - Systemd service and timer"
echo "  - Configuration files (/etc/update-notifier/)"
echo "  - Local secrets file (if present)"
echo ""
echo -e "${YELLOW}This will NOT remove:${NC}"
echo "  - unattended-upgrades/dnf-automatic package (system updates will continue)"
echo "  - Doppler CLI or configuration"
echo "  - Doppler secrets"
echo ""

read -p "Are you sure you want to uninstall? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Starting uninstall...${NC}\n"

# Stop and disable systemd service
if systemctl is-active --quiet update-notifier-discord.service 2>/dev/null; then
    echo -e "${YELLOW}Stopping systemd service...${NC}"
    systemctl stop update-notifier-discord.service || true
fi

if systemctl is-enabled --quiet update-notifier-discord.service 2>/dev/null; then
    echo -e "${YELLOW}Disabling systemd service...${NC}"
    systemctl disable update-notifier-discord.service || true
fi

# Remove systemd service file
if [[ -f /etc/systemd/system/update-notifier-discord.service ]]; then
    echo -e "${YELLOW}Removing systemd service file...${NC}"
    rm -f /etc/systemd/system/update-notifier-discord.service
    echo -e "  ${GREEN}✓${NC} Removed /etc/systemd/system/update-notifier-discord.service"
fi

# Remove systemd timer file
if [[ -f /etc/systemd/system/update-notifier-discord.timer ]]; then
    echo -e "${YELLOW}Removing systemd timer file...${NC}"
    rm -f /etc/systemd/system/update-notifier-discord.timer
    echo -e "  ${GREEN}✓${NC} Removed /etc/systemd/system/update-notifier-discord.timer"
fi

# Reload systemd
echo -e "${YELLOW}Reloading systemd daemon...${NC}"
systemctl daemon-reload

# Remove notification script
if [[ -f /usr/local/bin/update-notifier.sh ]]; then
    echo -e "${YELLOW}Removing notification script...${NC}"
    rm -f /usr/local/bin/update-notifier.sh
    echo -e "  ${GREEN}✓${NC} Removed /usr/local/bin/update-notifier.sh"
fi

# Remove configuration directory and secrets
if [[ -d /etc/update-notifier ]]; then
    echo -e "${YELLOW}Removing configuration directory...${NC}"
    if [[ -f /etc/update-notifier/secrets.conf ]]; then
        echo -e "  ${BLUE}ℹ${NC} Removing local secrets file"
        rm -f /etc/update-notifier/secrets.conf
    fi
    rm -rf /etc/update-notifier
    echo -e "  ${GREEN}✓${NC} Removed /etc/update-notifier/"
fi

# Remove APT hook
if [[ -f /etc/apt/apt.conf.d/99patch-gremlin-notification ]]; then
    echo -e "${YELLOW}Removing APT hook...${NC}"
    rm -f /etc/apt/apt.conf.d/99patch-gremlin-notification
    echo -e "  ${GREEN}✓${NC} Removed APT hook"
fi

# Remove old APT hook (legacy)
if [[ -f /etc/apt/apt.conf.d/99discord-notification ]]; then
    echo -e "${YELLOW}Removing legacy APT hook...${NC}"
    rm -f /etc/apt/apt.conf.d/99discord-notification
    echo -e "  ${GREEN}✓${NC} Removed legacy APT hook"
fi

# Remove DNF hook and override (RHEL systems)
if [[ -f /usr/local/bin/patch-gremlin-dnf-hook.sh ]]; then
    echo -e "${YELLOW}Removing DNF hook...${NC}"
    rm -f /usr/local/bin/patch-gremlin-dnf-hook.sh
    echo -e "  ${GREEN}✓${NC} Removed DNF hook"
fi

if [[ -f /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf ]]; then
    echo -e "${YELLOW}Removing DNF systemd override...${NC}"
    rm -f /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf
    rmdir /etc/systemd/system/dnf-automatic.service.d/ 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Removed DNF systemd override"
fi

# Backup unattended-upgrades config if it exists
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    echo -e "\n${YELLOW}Unattended-upgrades configuration found${NC}"
    echo "Do you want to:"
    echo "  1) Keep it (recommended - your system will still get automatic updates)"
    echo "  2) Remove it (disable automatic updates)"
    echo "  3) Restore from backup (if available)"
    echo ""
    read -p "Enter choice (1/2/3): " -n 1 -r CHOICE
    echo ""
    
    case $CHOICE in
        2)
            echo -e "${YELLOW}Removing unattended-upgrades configuration...${NC}"
            rm -f /etc/apt/apt.conf.d/50unattended-upgrades
            rm -f /etc/apt/apt.conf.d/20auto-upgrades
            echo -e "  ${GREEN}✓${NC} Removed unattended-upgrades configuration"
            ;;
        3)
            BACKUP=$(ls -t /etc/apt/apt.conf.d/50unattended-upgrades.backup.* 2>/dev/null | head -n1)
            if [[ -n "$BACKUP" ]]; then
                echo -e "${YELLOW}Restoring from backup: $BACKUP${NC}"
                cp "$BACKUP" /etc/apt/apt.conf.d/50unattended-upgrades
                echo -e "  ${GREEN}✓${NC} Restored from backup"
            else
                echo -e "  ${RED}✗${NC} No backup found"
            fi
            ;;
        *)
            echo -e "  ${GREEN}✓${NC} Keeping unattended-upgrades configuration"
            ;;
    esac
fi

echo ""
echo -e "${GREEN}=== Uninstall Complete ===${NC}\n"

echo -e "${BLUE}Summary:${NC}"
echo "  - Notification system removed"
echo "  - APT hooks removed"
echo "  - Systemd services removed"
echo ""

echo -e "${YELLOW}If you want to completely remove automatic updates:${NC}"
echo "  sudo apt-get remove --purge unattended-upgrades"
echo ""

echo -e "${YELLOW}Your Doppler configuration and secrets are still intact${NC}"
echo "If you want to remove Doppler secrets:"
echo "  sudo doppler secrets delete UPDATE_NOTIFIER_DISCORD_WEBHOOK"
echo "  sudo doppler secrets delete UPDATE_NOTIFIER_MATRIX_HOMESERVER"
echo "  sudo doppler secrets delete UPDATE_NOTIFIER_MATRIX_USERNAME"
echo "  sudo doppler secrets delete UPDATE_NOTIFIER_MATRIX_PASSWORD"
echo "  sudo doppler secrets delete UPDATE_NOTIFIER_MATRIX_ROOM_ID"
echo ""

echo -e "${GREEN}Done!${NC}"
