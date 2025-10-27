#!/bin/bash

# Setup script for automatic security updates on Debian Trixie with Discord/Matrix notifications
# This script configures unattended-upgrades and integrates multi-platform notifiers

set -e

# Load configuration from file if it exists
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "Loading configuration from $SCRIPT_DIR/config.sh"
    source "$SCRIPT_DIR/config.sh"
elif [[ -f /etc/update-notifier/config.sh ]]; then
    echo "Loading configuration from /etc/update-notifier/config.sh"
    source /etc/update-notifier/config.sh
fi

# Configuration - Set defaults for any variables not set by config.sh
DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
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

echo -e "${GREEN}Setting up automatic security updates for Debian Trixie...${NC}"
echo -e "${BLUE}Doppler secret names:${NC}"
echo -e "  Discord Webhook: ${YELLOW}$DOPPLER_DISCORD_SECRET${NC}"
echo -e "  Matrix Webhook:  ${YELLOW}$DOPPLER_MATRIX_SECRET${NC}"
echo -e "  Matrix API:"
echo -e "    - Homeserver: ${YELLOW}$DOPPLER_MATRIX_HOMESERVER_SECRET${NC}"
echo -e "    - Username:   ${YELLOW}$DOPPLER_MATRIX_USERNAME_SECRET${NC}"
echo -e "    - Password:   ${YELLOW}$DOPPLER_MATRIX_PASSWORD_SECRET${NC}"
echo -e "    - Room ID:    ${YELLOW}$DOPPLER_MATRIX_ROOM_ID_SECRET${NC}"
echo ""
echo -e "  Discord: ${YELLOW}$DOPPLER_DISCORD_SECRET${NC}"
echo -e "  Matrix:  ${YELLOW}$DOPPLER_MATRIX_SECRET${NC}"
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

# Install unattended-upgrades if not already installed
echo -e "${YELLOW}Installing unattended-upgrades package...${NC}"
apt-get update
apt-get install -y unattended-upgrades apt-listchanges

# Create unattended-upgrades configuration
echo -e "${YELLOW}Configuring unattended-upgrades...${NC}"

# Backup existing config if it exists
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades.backup.$(date +%Y%m%d-%H%M%S)
fi

# Create the main unattended-upgrades configuration
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Automatically upgrade packages from these origins
Unattended-Upgrade::Origins-Pattern {
    // Security updates for Debian Trixie
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security";
    
    // You can also enable regular updates (optional)
    // "origin=Debian,codename=${distro_codename},label=Debian";
    // "origin=Debian,codename=${distro_codename}-updates";
};

// List of packages to NOT automatically upgrade
Unattended-Upgrade::Package-Blacklist {
    // Add packages here that you don't want auto-updated
    // "vim";
    // "nginx";
};

// Automatically reboot if needed (at specified time)
Unattended-Upgrade::Automatic-Reboot "false";

// If automatic reboot is enabled, reboot at this time
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Automatically reboot even if users are logged in
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Remove unused automatically installed kernel-related packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatically remove new unused dependencies after the upgrade
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Send email notifications (optional, requires mail setup)
// Unattended-Upgrade::Mail "root";
// Unattended-Upgrade::MailReport "on-change";

// Enable logging to syslog
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";

// Verbose logging
Unattended-Upgrade::Verbose "true";
EOF

# Create auto-upgrades configuration
echo -e "${YELLOW}Enabling automatic updates...${NC}"

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
// Enable automatic package list updates
APT::Periodic::Update-Package-Lists "1";

// Enable automatic download of upgradeable packages
APT::Periodic::Download-Upgradeable-Packages "1";

// Enable automatic upgrade of packages
APT::Periodic::Unattended-Upgrade "1";

// Auto-clean interval (in days)
APT::Periodic::AutocleanInterval "7";

// Verbose level (0=no output, 1=some, 2=more, 3=debug)
APT::Periodic::Verbose "2";
EOF

# Copy the Discord notifier script to the system
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Create systemd service for post-upgrade notification
echo -e "${YELLOW}Creating systemd service for notifications...${NC}"

cat > /etc/systemd/system/update-notifier-discord.service << EOF
[Unit]
Description=Update Notification Service (Discord/Matrix)
After=apt-daily-upgrade.service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="DOPPLER_DISCORD_SECRET=$DOPPLER_DISCORD_SECRET"
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

# Create systemd timer to trigger after apt-daily-upgrade
cat > /etc/systemd/system/update-notifier-discord.timer << 'EOF'
[Unit]
Description=Timer for Discord Update Notifications
After=apt-daily-upgrade.service

[Timer]
# Run 5 minutes after the apt-daily-upgrade service completes
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Alternative: Create a hook script that runs after unattended-upgrades
echo -e "${YELLOW}Creating post-upgrade hook...${NC}"
mkdir -p /etc/apt/apt.conf.d/

cat > /etc/apt/apt.conf.d/99discord-notification << EOF
// Run notification script after unattended-upgrades completes
// Pass custom Doppler secret names as environment variables
Dpkg::Post-Invoke {
    "if [ -x /usr/local/bin/update-notifier.sh ]; then DOPPLER_DISCORD_SECRET='$DOPPLER_DISCORD_SECRET' DOPPLER_MATRIX_SECRET='$DOPPLER_MATRIX_SECRET' DOPPLER_MATRIX_HOMESERVER_SECRET='$DOPPLER_MATRIX_HOMESERVER_SECRET' DOPPLER_MATRIX_USERNAME_SECRET='$DOPPLER_MATRIX_USERNAME_SECRET' DOPPLER_MATRIX_PASSWORD_SECRET='$DOPPLER_MATRIX_PASSWORD_SECRET' DOPPLER_MATRIX_ROOM_ID_SECRET='$DOPPLER_MATRIX_ROOM_ID_SECRET' /usr/local/bin/update-notifier.sh || true; fi";
};
EOF

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
