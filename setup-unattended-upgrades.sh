#!/bin/bash

# Patch Gremlin - Setup Script
# Configures automatic security updates on Debian/RHEL with Discord/Matrix notifications
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -e

# Detect OS type
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID}"
    OS_LIKE="${ID_LIKE}"
else
    echo "Error: Cannot detect OS type. /etc/os-release not found."
    exit 1
fi

# Determine if Debian-based or RHEL-based
if [[ "$OS_ID" =~ ^(debian|ubuntu)$ ]] || [[ "$OS_LIKE" =~ debian ]]; then
    OS_TYPE="debian"
    PACKAGE_MANAGER="apt"
elif [[ "$OS_ID" =~ ^(rhel|centos|rocky|almalinux|fedora|amzn)$ ]] || [[ "$OS_LIKE" =~ rhel|fedora ]]; then
    OS_TYPE="rhel"
    PACKAGE_MANAGER="dnf"
else
    echo "Error: Unsupported OS: $OS_ID"
    echo "Supported: Debian, Ubuntu, RHEL, Rocky, AlmaLinux, Amazon Linux, Fedora"
    exit 1
fi

echo "Detected OS: $OS_ID $OS_VERSION (type: $OS_TYPE)"

# Ask user about update scope (unless already set via environment)
if [[ -z "$UPDATE_TYPE" ]]; then
    echo -e "\n${YELLOW}Update Configuration:${NC}"
    echo "What type of updates should be automatically installed?"
    echo "  1) Security updates only (recommended)"
    echo "  2) All available updates"
    echo ""
    read -p "Enter choice [1-2] (default: 1): " -n 1 -r UPDATE_SCOPE
    echo ""
    if [[ -z "$UPDATE_SCOPE" ]] || [[ "$UPDATE_SCOPE" == "1" ]]; then
        UPDATE_TYPE="security"
        echo -e "${GREEN}Selected: Security updates only${NC}"
    else
        UPDATE_TYPE="all"
        echo -e "${GREEN}Selected: All available updates${NC}"
    fi
else
    echo -e "\n${GREEN}Using preset configuration: ${UPDATE_TYPE} updates${NC}"
fi
echo ""

# Ask user about update schedule (unless already set via environment)
if [[ -z "$UPDATE_SCHEDULE" ]]; then
    echo -e "${YELLOW}Update Schedule:${NC}"
    echo "How often should updates be checked and installed?"
    echo "  1) Daily (recommended for security)"
    echo "  2) Weekly"
    echo ""
    read -p "Enter choice [1-2] (default: 1): " -n 1 -r SCHEDULE_CHOICE
    echo ""
    if [[ -z "$SCHEDULE_CHOICE" ]] || [[ "$SCHEDULE_CHOICE" == "1" ]]; then
        UPDATE_SCHEDULE="daily"
        echo -e "${GREEN}Selected: Daily updates${NC}"
    else
        UPDATE_SCHEDULE="weekly"
        echo -e "${GREEN}Selected: Weekly updates${NC}"
        echo ""
        echo -e "${YELLOW}Which day of the week?${NC}"
        echo "  1) Sunday    2) Monday    3) Tuesday   4) Wednesday"
        echo "  5) Thursday  6) Friday    7) Saturday"
        echo ""
        read -p "Enter choice [1-7] (default: 7 - Saturday): " -n 1 -r DAY_CHOICE
        echo ""
        case "$DAY_CHOICE" in
            1) UPDATE_DAY="Sun" ;;
            2) UPDATE_DAY="Mon" ;;
            3) UPDATE_DAY="Tue" ;;
            4) UPDATE_DAY="Wed" ;;
            5) UPDATE_DAY="Thu" ;;
            6) UPDATE_DAY="Fri" ;;
            *) UPDATE_DAY="Sat" ;;
        esac
        echo -e "${GREEN}Selected: Weekly updates on ${UPDATE_DAY}day${NC}"
    fi
    
    # Ask for time of day
    echo ""
    echo -e "${YELLOW}What time should updates run?${NC}"
    echo "Enter time in 24-hour format (HH:MM, default: 02:00):"
    read -p "Time: " UPDATE_TIME
    if [[ -z "$UPDATE_TIME" ]]; then
        UPDATE_TIME="02:00"
    fi
    # Validate time format
    if [[ ! "$UPDATE_TIME" =~ ^([0-1]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo -e "${YELLOW}Invalid time format, using default 02:00${NC}"
        UPDATE_TIME="02:00"
    fi
    echo -e "${GREEN}Selected: Updates at ${UPDATE_TIME}${NC}"
else
    echo -e "\n${GREEN}Using preset schedule: ${UPDATE_SCHEDULE}${NC}"
    UPDATE_TIME="${UPDATE_TIME:-02:00}"
fi
echo ""

# Load configuration from file if it exists
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.sh" ]] && [[ -r "$SCRIPT_DIR/config.sh" ]]; then
    echo "Loading configuration from $SCRIPT_DIR/config.sh"
    # Basic validation: check if file contains only variable assignments
    if grep -q '^[[:space:]]*export[[:space:]]\+[A-Z_][A-Z0-9_]*=' "$SCRIPT_DIR/config.sh"; then
        source "$SCRIPT_DIR/config.sh"
    else
        echo -e "${YELLOW}Warning: config.sh doesn't appear to contain valid configuration${NC}"
    fi
elif [[ -f /etc/update-notifier/config.sh ]] && [[ -r /etc/update-notifier/config.sh ]]; then
    echo "Loading configuration from /etc/update-notifier/config.sh"
    if grep -q '^[[:space:]]*export[[:space:]]\+[A-Z_][A-Z0-9_]*=' /etc/update-notifier/config.sh; then
        source /etc/update-notifier/config.sh
    else
        echo -e "${YELLOW}Warning: config.sh doesn't appear to contain valid configuration${NC}"
    fi
fi

# Configuration - Set defaults for any variables not set by config.sh
DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
DOPPLER_TEAMS_SECRET="${DOPPLER_TEAMS_SECRET:-UPDATE_NOTIFIER_TEAMS_WEBHOOK}"
DOPPLER_SLACK_SECRET="${DOPPLER_SLACK_SECRET:-UPDATE_NOTIFIER_SLACK_WEBHOOK}"
DOPPLER_MATRIX_SECRET="${DOPPLER_MATRIX_SECRET:-UPDATE_NOTIFIER_MATRIX_WEBHOOK}"
DOPPLER_MATRIX_HOMESERVER_SECRET="${DOPPLER_MATRIX_HOMESERVER_SECRET:-UPDATE_NOTIFIER_MATRIX_HOMESERVER}"
DOPPLER_MATRIX_USERNAME_SECRET="${DOPPLER_MATRIX_USERNAME_SECRET:-UPDATE_NOTIFIER_MATRIX_USERNAME}"
DOPPLER_MATRIX_PASSWORD_SECRET="${DOPPLER_MATRIX_PASSWORD_SECRET:-UPDATE_NOTIFIER_MATRIX_PASSWORD}"
DOPPLER_MATRIX_ROOM_ID_SECRET="${DOPPLER_MATRIX_ROOM_ID_SECRET:-UPDATE_NOTIFIER_MATRIX_ROOM_ID}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# OS-specific installation functions
install_debian_updates() {
    echo -e "${YELLOW}Installing unattended-upgrades package...${NC}"
    apt-get update
    apt-get install -y unattended-upgrades apt-listchanges

    echo -e "${YELLOW}Configuring unattended-upgrades...${NC}"
    
    # Backup existing config if it exists
    if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
        cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades.backup.$(date +%Y%m%d-%H%M%S)
    fi

    # Create the main unattended-upgrades configuration
    if [[ "$UPDATE_TYPE" == "security" ]]; then
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Automatically upgrade packages from these origins
Unattended-Upgrade::Origins-Pattern {
    // Security updates only
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security";
    "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
};
EOF
    else
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Automatically upgrade packages from these origins
Unattended-Upgrade::Origins-Pattern {
    // Security updates
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security";
    "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
    // All updates
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Ubuntu,archive=${distro_codename},label=Ubuntu";
    "origin=Ubuntu,archive=${distro_codename}-updates,label=Ubuntu";
};
EOF
    fi
    
    cat >> /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'

// List of packages to NOT automatically upgrade
Unattended-Upgrade::Package-Blacklist {
};

// Automatically reboot if needed
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Remove unused packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Logging
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
Unattended-Upgrade::Verbose "true";
EOF

    # Create auto-upgrades configuration based on schedule
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "7";
APT::Periodic::Download-Upgradeable-Packages "7";
APT::Periodic::Unattended-Upgrade "7";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "2";
EOF
    else
        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "2";
EOF
    fi

    echo -e "  ${GREEN}✓${NC} Configured unattended-upgrades for Debian/Ubuntu (${UPDATE_TYPE} updates)"
}

install_rhel_updates() {
    echo -e "${YELLOW}Installing dnf-automatic package...${NC}"
    "$PACKAGE_MANAGER" install -y dnf-automatic

    echo -e "${YELLOW}Configuring dnf-automatic...${NC}"
    
    # Backup existing config if it exists
    if [[ -f /etc/dnf/automatic.conf ]]; then
        cp /etc/dnf/automatic.conf /etc/dnf/automatic.conf.backup.$(date +%Y%m%d-%H%M%S)
    fi

    # Configure dnf-automatic based on user choice
    if [[ "$UPDATE_TYPE" == "security" ]]; then
        UPGRADE_TYPE_SETTING="security"
        echo -e "  ${BLUE}Configuring for security updates only${NC}"
    else
        UPGRADE_TYPE_SETTING="default"
        echo -e "  ${BLUE}Configuring for all available updates${NC}"
    fi
    
    cat > /etc/dnf/automatic.conf << EOF
[commands]
# What kind of upgrade to perform:
# default                   = all available upgrades
# security                  = only security upgrades
upgrade_type = $UPGRADE_TYPE_SETTING
random_sleep = 0

# Whether updates should be downloaded when they are available
download_updates = yes

# Whether updates should be applied when they are available
apply_updates = yes

[emitters]
# Emit via systemd (for our notification script)
emit_via = motd

[email]
# Email settings (optional)
email_from = root@localhost
email_to = root
email_host = localhost

[base]
# Use yum-conf-dir for CentOS 7 compatibility
debuglevel = 1
EOF

    # Configure dnf-automatic timer based on user schedule
    mkdir -p /etc/systemd/system/dnf-automatic.timer.d/
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        cat > /etc/systemd/system/dnf-automatic.timer.d/schedule.conf << EOF
[Timer]
# Override default schedule - run weekly on ${UPDATE_DAY}day at ${UPDATE_TIME}
OnCalendar=
OnCalendar=${UPDATE_DAY} *-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
EOF
    else
        cat > /etc/systemd/system/dnf-automatic.timer.d/schedule.conf << EOF
[Timer]
# Override default schedule - run daily at ${UPDATE_TIME}
OnCalendar=
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
EOF
    fi
    
    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable --now dnf-automatic.timer
    
    echo -e "  ${GREEN}✓${NC} Configured dnf-automatic for RHEL/Fedora/Amazon Linux (${UPDATE_TYPE} updates)"
}

echo -e "${GREEN}Setting up automatic security updates for $OS_ID...${NC}"
echo -e "${BLUE}Doppler secret names configured:${NC}"
echo -e "  Discord:        ${YELLOW}$DOPPLER_DISCORD_SECRET${NC}"
echo -e "  Teams:          ${YELLOW}$DOPPLER_TEAMS_SECRET${NC}"
echo -e "  Slack:          ${YELLOW}$DOPPLER_SLACK_SECRET${NC}"
echo -e "  Matrix Webhook: ${YELLOW}$DOPPLER_MATRIX_SECRET${NC}"
echo -e "  Matrix API:"
echo -e "    - Homeserver: ${YELLOW}$DOPPLER_MATRIX_HOMESERVER_SECRET${NC}"
echo -e "    - Username:   ${YELLOW}$DOPPLER_MATRIX_USERNAME_SECRET${NC}"
echo -e "    - Password:   ${YELLOW}$DOPPLER_MATRIX_PASSWORD_SECRET${NC}"
echo -e "    - Room ID:    ${YELLOW}$DOPPLER_MATRIX_ROOM_ID_SECRET${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   echo "Please run: sudo -E $0"
   echo ""
   echo -e "${YELLOW}Note: Use -E flag to preserve environment variables if you have custom secret names${NC}"
   exit 1
fi

# Check if Doppler is configured for root
if ! doppler configure get project &>/dev/null; then
    echo -e "${YELLOW}Warning: Doppler is not configured for the root user${NC}"
    echo ""
    echo "Please run these commands first:"
    echo -e "  ${BLUE}sudo doppler login${NC}"
    echo -e "  ${BLUE}cd $(pwd) && sudo doppler setup${NC}"
    echo ""
    read -p "Would you like to configure Doppler now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        doppler login
        doppler setup
    else
        echo -e "${RED}Doppler must be configured before continuing${NC}"
        exit 1
    fi
fi

# Install and configure automatic updates based on OS type
if [[ "$OS_TYPE" == "debian" ]]; then
    install_debian_updates
elif [[ "$OS_TYPE" == "rhel" ]]; then
    install_rhel_updates
fi

# Copy the notifier script to the system
NOTIFIER_SCRIPT="$SCRIPT_DIR/update-notifier.sh"

if [[ ! -f "$NOTIFIER_SCRIPT" ]]; then
    echo -e "${RED}Error: Notifier script not found at $NOTIFIER_SCRIPT${NC}"
    exit 1
fi

echo -e "${YELLOW}Installing notification script...${NC}"
cp "$NOTIFIER_SCRIPT" /usr/local/bin/update-notifier.sh
chmod +x /usr/local/bin/update-notifier.sh

# Copy config file to system location if it exists
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    echo -e "${YELLOW}Installing configuration file...${NC}"
    mkdir -p /etc/update-notifier
    cp "$SCRIPT_DIR/config.sh" /etc/update-notifier/config.sh
    chmod 644 /etc/update-notifier/config.sh
    echo -e "  ${GREEN}✓${NC} Copied config to /etc/update-notifier/config.sh"
fi

# Clean up old service files if they exist
if [[ -f /etc/systemd/system/update-notifier-discord.service ]]; then
    echo -e "${YELLOW}Removing old service files...${NC}"
    systemctl stop update-notifier-discord.service 2>/dev/null || true
    systemctl disable update-notifier-discord.service 2>/dev/null || true
    rm -f /etc/systemd/system/update-notifier-discord.service
    rm -f /etc/systemd/system/update-notifier-discord.timer
fi

# Create systemd service for post-upgrade notification
echo -e "${YELLOW}Creating systemd service for notifications...${NC}"

cat > /etc/systemd/system/update-notifier.service << EOF
[Unit]
Description=Update Notification Service
After=apt-daily-upgrade.service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="DOPPLER_DISCORD_SECRET=$DOPPLER_DISCORD_SECRET"
Environment="DOPPLER_TEAMS_SECRET=$DOPPLER_TEAMS_SECRET"
Environment="DOPPLER_SLACK_SECRET=$DOPPLER_SLACK_SECRET"
Environment="DOPPLER_MATRIX_SECRET=$DOPPLER_MATRIX_SECRET"
Environment="DOPPLER_MATRIX_HOMESERVER_SECRET=$DOPPLER_MATRIX_HOMESERVER_SECRET"
Environment="DOPPLER_MATRIX_USERNAME_SECRET=$DOPPLER_MATRIX_USERNAME_SECRET"
Environment="DOPPLER_MATRIX_PASSWORD_SECRET=$DOPPLER_MATRIX_PASSWORD_SECRET"
Environment="DOPPLER_MATRIX_ROOM_ID_SECRET=$DOPPLER_MATRIX_ROOM_ID_SECRET"
ExecStart=/usr/local/bin/update-notifier.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create systemd timer based on schedule
if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
    cat > /etc/systemd/system/update-notifier.timer << EOF
[Unit]
Description=Timer for Update Notifications
Requires=update-notifier.service

[Timer]
# Run weekly on ${UPDATE_DAY}day at ${UPDATE_TIME}
OnCalendar=${UPDATE_DAY} *-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
else
    cat > /etc/systemd/system/update-notifier.timer << EOF
[Unit]
Description=Timer for Update Notifications
Requires=update-notifier.service

[Timer]
# Run daily at ${UPDATE_TIME}
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

# Create post-upgrade hook (OS-specific)
if [[ "$OS_TYPE" == "debian" ]]; then
    echo -e "${YELLOW}Creating APT post-upgrade hook...${NC}"
    mkdir -p /etc/apt/apt.conf.d/
    
    cat > /etc/apt/apt.conf.d/99patch-gremlin-notification << EOF
// Run Patch Gremlin notification script after unattended-upgrades completes
Dpkg::Post-Invoke {
    "if [ -x /usr/local/bin/update-notifier.sh ]; then DOPPLER_DISCORD_SECRET='$DOPPLER_DISCORD_SECRET' DOPPLER_TEAMS_SECRET='$DOPPLER_TEAMS_SECRET' DOPPLER_SLACK_SECRET='$DOPPLER_SLACK_SECRET' DOPPLER_MATRIX_SECRET='$DOPPLER_MATRIX_SECRET' DOPPLER_MATRIX_HOMESERVER_SECRET='$DOPPLER_MATRIX_HOMESERVER_SECRET' DOPPLER_MATRIX_USERNAME_SECRET='$DOPPLER_MATRIX_USERNAME_SECRET' DOPPLER_MATRIX_PASSWORD_SECRET='$DOPPLER_MATRIX_PASSWORD_SECRET' DOPPLER_MATRIX_ROOM_ID_SECRET='$DOPPLER_MATRIX_ROOM_ID_SECRET' /usr/local/bin/update-notifier.sh || true; fi";
};
EOF
    echo -e "  ${GREEN}✓${NC} Created APT post-upgrade hook"
    
elif [[ "$OS_TYPE" == "rhel" ]]; then
    echo -e "${YELLOW}Creating DNF post-upgrade hook...${NC}"
    
    cat > /usr/local/bin/patch-gremlin-dnf-hook.sh << 'HOOKEOF'
#!/bin/bash
# Patch Gremlin DNF hook - Run after DNF transactions
if [[ -x /usr/local/bin/update-notifier.sh ]]; then
    /usr/local/bin/update-notifier.sh || true
fi
HOOKEOF
    chmod +x /usr/local/bin/patch-gremlin-dnf-hook.sh
    
    # Create systemd override for dnf-automatic to run our hook
    mkdir -p /etc/systemd/system/dnf-automatic.service.d/
    cat > /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf << EOF
[Service]
ExecStartPost=/usr/local/bin/patch-gremlin-dnf-hook.sh
Environment="DOPPLER_DISCORD_SECRET=$DOPPLER_DISCORD_SECRET"
Environment="DOPPLER_TEAMS_SECRET=$DOPPLER_TEAMS_SECRET"
Environment="DOPPLER_SLACK_SECRET=$DOPPLER_SLACK_SECRET"
Environment="DOPPLER_MATRIX_SECRET=$DOPPLER_MATRIX_SECRET"
Environment="DOPPLER_MATRIX_HOMESERVER_SECRET=$DOPPLER_MATRIX_HOMESERVER_SECRET"
Environment="DOPPLER_MATRIX_USERNAME_SECRET=$DOPPLER_MATRIX_USERNAME_SECRET"
Environment="DOPPLER_MATRIX_PASSWORD_SECRET=$DOPPLER_MATRIX_PASSWORD_SECRET"
Environment="DOPPLER_MATRIX_ROOM_ID_SECRET=$DOPPLER_MATRIX_ROOM_ID_SECRET"
EOF
    echo -e "  ${GREEN}✓${NC} Created DNF post-upgrade hook"
fi

# Reload systemd
systemctl daemon-reload

echo -e "${GREEN}Configuration complete!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Install Doppler CLI if not already installed:"
echo "   curl -Ls https://cli.doppler.com/install.sh | sh"
echo ""
echo "2. Authenticate with Doppler:"
echo "   doppler login"
echo ""
echo "3. Set up Doppler for this system (as root):"
echo "   sudo doppler setup"
echo ""
echo "4. Add webhook URL(s) to Doppler (at least one required):"
echo -e "   ${BLUE}For Discord:${NC}"
echo "   sudo doppler secrets set $DOPPLER_DISCORD_SECRET='https://discord.com/api/webhooks/YOUR_WEBHOOK_URL'"
echo ""
echo -e "   ${BLUE}For Matrix (choose one method):${NC}"
echo -e "   ${YELLOW}Method 1: Webhook (if available)${NC}"
echo "   sudo doppler secrets set $DOPPLER_MATRIX_SECRET='https://matrix.example.org/_matrix/webhook/YOUR_WEBHOOK'"
echo ""
echo -e "   ${YELLOW}Method 2: Matrix API (recommended)${NC}"
echo "   sudo doppler secrets set $DOPPLER_MATRIX_HOMESERVER_SECRET='https://matrix.org'"
echo "   sudo doppler secrets set $DOPPLER_MATRIX_USERNAME_SECRET='@youruser:matrix.org'"
echo "   sudo doppler secrets set $DOPPLER_MATRIX_PASSWORD_SECRET='your_matrix_password'"
echo "   sudo doppler secrets set $DOPPLER_MATRIX_ROOM_ID_SECRET='!your_room_id:matrix.org'"
echo ""
echo -e "   ${BLUE}To find your Matrix room ID:${NC}"
echo "   In Element: Room Settings → Advanced → Internal room ID"
echo ""
echo "5. Test the notification script:"
echo "   sudo /usr/local/bin/update-notifier.sh"
echo ""
echo "6. Test unattended-upgrades dry-run:"
echo "   sudo unattended-upgrade --dry-run --debug"
echo ""
echo "7. Force an immediate update check (optional):"
echo "   sudo unattended-upgrade --debug"
echo ""
echo -e "${BLUE}Customizing Doppler secret names:${NC}"
echo "If you need different secret names to avoid conflicts with other programs,"
echo "set these environment variables before running the setup:"
echo "   export DOPPLER_DISCORD_SECRET='MY_CUSTOM_DISCORD_SECRET'"
echo "   export DOPPLER_MATRIX_SECRET='MY_CUSTOM_MATRIX_SECRET'"
echo "   sudo -E ./setup-unattended-upgrades.sh"
echo ""
echo -e "${GREEN}Automatic security updates are now configured!${NC}"
echo "The system will check for updates daily and send notifications after applying them."
