#!/bin/bash

# Patch Gremlin Uninstaller
# Removes all installed components

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Patch Gremlin Uninstaller${NC}"
echo "This will remove all Patch Gremlin components."
echo ""
echo "Options:"
echo "  1) Remove Patch Gremlin only (keep unattended-upgrades/dnf-automatic)"
echo "  2) Remove everything including update systems"
echo "  3) Cancel"
echo ""
read -p "Enter choice [1-3] (default: 1): " -n 1 -r UNINSTALL_TYPE
echo ""

case "$UNINSTALL_TYPE" in
    2) REMOVE_UPDATE_SYSTEM=true ;;
    3|*) 
        if [[ "$UNINSTALL_TYPE" == "3" ]]; then
            echo "Uninstall cancelled."
            exit 0
        fi
        REMOVE_UPDATE_SYSTEM=false
        ;;
esac

echo -e "${YELLOW}Stopping and disabling services...${NC}"
systemctl stop update-notifier.timer 2>/dev/null || true
systemctl disable update-notifier.timer 2>/dev/null || true
systemctl stop update-notifier.service 2>/dev/null || true
systemctl disable update-notifier.service 2>/dev/null || true

echo -e "${YELLOW}Removing systemd files...${NC}"
rm -f /etc/systemd/system/update-notifier.service
rm -f /etc/systemd/system/update-notifier.timer
systemctl daemon-reload

echo -e "${YELLOW}Removing scripts...${NC}"
rm -f /usr/local/bin/update-notifier.sh
rm -f /usr/local/bin/patch-gremlin-health-check.sh
rm -f /usr/local/bin/patch-gremlin-dnf-hook.sh

# Remove any monitoring scripts we might have installed
rm -f /usr/local/bin/nagios-check.sh
rm -f /usr/local/bin/prometheus-exporter.sh

echo -e "${YELLOW}Removing configuration...${NC}"
rm -rf /etc/update-notifier/

echo -e "${YELLOW}Removing hooks and overrides...${NC}"
# Debian/Ubuntu
rm -f /etc/apt/apt.conf.d/99patch-gremlin-notification

# RHEL/Fedora
rm -f /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf
rmdir /etc/systemd/system/dnf-automatic.service.d/ 2>/dev/null || true

# Remove timer overrides
rm -rf /etc/systemd/system/apt-daily-upgrade.timer.d/
rm -rf /etc/systemd/system/dnf-automatic.timer.d/

if [[ "$REMOVE_UPDATE_SYSTEM" == "true" ]]; then
    echo -e "${YELLOW}Removing update systems...${NC}"
    
    # Stop and disable update services
    systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop dnf-automatic.timer 2>/dev/null || true
    systemctl disable dnf-automatic.timer 2>/dev/null || true
    
    # Remove packages
    if command -v apt-get &>/dev/null; then
        apt-get remove -y unattended-upgrades 2>/dev/null || true
        rm -f /etc/apt/apt.conf.d/50unattended-upgrades*
        rm -f /etc/apt/apt.conf.d/20auto-upgrades*
    fi
    
    if command -v dnf &>/dev/null; then
        dnf remove -y dnf-automatic 2>/dev/null || true
        rm -f /etc/dnf/automatic.conf*
    fi
    
    echo "Removed update systems"
else
    echo -e "${YELLOW}Restoring original configs...${NC}"
    # Restore unattended-upgrades if backup exists
    if ls /etc/apt/apt.conf.d/50unattended-upgrades.backup.* &>/dev/null; then
        latest_backup=$(ls -t /etc/apt/apt.conf.d/50unattended-upgrades.backup.* | head -1)
        cp "$latest_backup" /etc/apt/apt.conf.d/50unattended-upgrades
        echo "Restored unattended-upgrades config from backup"
    fi
    
    # Restore dnf-automatic if backup exists
    if ls /etc/dnf/automatic.conf.backup.* &>/dev/null; then
        latest_backup=$(ls -t /etc/dnf/automatic.conf.backup.* | head -1)
        cp "$latest_backup" /etc/dnf/automatic.conf
        echo "Restored dnf-automatic config from backup"
    fi
    
    # Re-enable original timers
    systemctl enable apt-daily-upgrade.timer 2>/dev/null || true
    systemctl start apt-daily-upgrade.timer 2>/dev/null || true
    systemctl enable dnf-automatic.timer 2>/dev/null || true
    systemctl start dnf-automatic.timer 2>/dev/null || true
fi

systemctl daemon-reload

# Clean up monitoring scripts
echo -e "${YELLOW}Removing monitoring components...${NC}"
rm -f /usr/local/bin/nagios-check.sh
rm -f /usr/local/bin/prometheus-exporter.sh

# Remove from crontab if present
crontab -l 2>/dev/null | grep -v "prometheus-exporter.sh" | crontab - 2>/dev/null || true

echo ""
echo -e "${GREEN}✓ Patch Gremlin has been completely removed${NC}"
echo ""
if [[ "$REMOVE_UPDATE_SYSTEM" == "true" ]]; then
    echo -e "${YELLOW}Warning: Automatic updates are now disabled!${NC}"
    echo "Your system will no longer receive automatic security updates."
else
    echo "Automatic updates are still enabled and will continue working."
fi
echo ""
echo "Optional cleanup:"
echo "• Remove Doppler: sudo rm -rf /root/.doppler/"
echo "• Remove backup configs: sudo rm -f /etc/apt/apt.conf.d/*.backup.* /etc/dnf/automatic.conf.backup.*"
echo "• Clear logs: sudo journalctl --vacuum-time=1d"
