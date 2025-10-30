#!/bin/bash

# Patch Gremlin - Setup Script
# Configures automatic security updates on Debian/RHEL with Discord/Matrix notifications
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Pre-installation checks
echo -e "\033[0;34m=== Patch Gremlin Setup ===\033[0m"
echo "Performing pre-installation checks..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31mError: This script must be run as root\033[0m" 
   echo "Please run: sudo -E $0"
   exit 1
fi

# Check internet connectivity
if ! curl -s --max-time 5 https://api.github.com >/dev/null; then
    echo -e "\033[1;33mWarning: Limited internet connectivity detected\033[0m"
fi

# Check available disk space (need at least 100MB)
AVAIL_SPACE=$(df /usr/local 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
if [[ $AVAIL_SPACE -lt 100000 ]]; then
    echo -e "\033[1;33mWarning: Low disk space in /usr/local\033[0m"
fi

# Detect OS type
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID}"
    OS_LIKE="${ID_LIKE:-}"
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

# Check for existing installation
EXISTING_INSTALL=false
if [[ -f /usr/local/bin/update-notifier.sh ]] || [[ -f /etc/systemd/system/update-notifier.service ]]; then
    EXISTING_INSTALL=true
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}    Existing Installation Detected${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Patch Gremlin is already installed on this system."
    echo ""
    
    # Show current configuration
    if [[ -f /etc/update-notifier/secrets.conf ]]; then
        echo "Current mode: LOCAL file storage"
    elif systemctl show update-notifier.service 2>/dev/null | grep -q "DOPPLER_TOKEN="; then
        echo "Current mode: DOPPLER"
    fi
    
    if systemctl is-enabled update-notifier.timer &>/dev/null; then
        echo "Timer status: ENABLED"
    else
        echo "Timer status: DISABLED"
    fi
    
    echo ""
    echo "Options:"
    echo "  1) Reinstall/Reconfigure (preserves nothing)"
    echo "  2) Update scripts only (keeps configuration)"
    echo "  3) Cancel installation"
    echo ""
    read -p "Enter choice [1-3] (default: 3): " -n 1 -r INSTALL_CHOICE
    echo ""
    
    case "$INSTALL_CHOICE" in
        1)
            echo -e "${YELLOW}Reinstalling from scratch...${NC}"
            echo "Note: You'll need to reconfigure all settings"
            ;;
        2)
            echo -e "${GREEN}Updating scripts only...${NC}"
            # Copy new scripts
            cp "$SCRIPT_DIR/update-notifier.sh" /usr/local/bin/update-notifier.sh
            chmod +x /usr/local/bin/update-notifier.sh
            systemctl daemon-reload
            echo -e "${GREEN}✓ Scripts updated${NC}"
            echo ""
            echo "Configuration preserved. To reconfigure, run option 1."
            exit 0
            ;;
        3|*)
            echo "Installation cancelled."
            exit 0
            ;;
    esac
    echo ""
fi

# Initialize variables with defaults
UPDATE_TYPE="${UPDATE_TYPE:-}"
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-}"
SYSTEM_TIMEZONE="${SYSTEM_TIMEZONE:-}"
SECRET_MODE="${SECRET_MODE:-}"
UPDATE_TIME="${UPDATE_TIME:-02:00}"

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

# Ask about timezone (unless already set via environment)
if [[ -z "$SYSTEM_TIMEZONE" ]]; then
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")
    echo ""
    echo -e "${YELLOW}Timezone Configuration:${NC}"
    echo "Current timezone: ${BLUE}$CURRENT_TZ${NC}"
    echo "Current time: $(date)"
    echo ""
    read -p "Keep current timezone? (y/n) [default: y]: " -n 1 -r TZ_CHOICE
    echo ""
    
    if [[ "$TZ_CHOICE" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Select timezone:${NC}"
        echo "  1) US/Eastern     2) US/Central     3) US/Mountain    4) US/Pacific"
        echo "  5) Europe/London  6) Europe/Paris   7) Asia/Tokyo     8) UTC"
        echo "  9) Other (manual entry)"
        echo ""
        read -p "Enter choice [1-9] (default: 8 - UTC): " -n 1 -r TZ_SELECTION
        echo ""
        
        case "$TZ_SELECTION" in
            1) NEW_TIMEZONE="US/Eastern" ;;
            2) NEW_TIMEZONE="US/Central" ;;
            3) NEW_TIMEZONE="US/Mountain" ;;
            4) NEW_TIMEZONE="US/Pacific" ;;
            5) NEW_TIMEZONE="Europe/London" ;;
            6) NEW_TIMEZONE="Europe/Paris" ;;
            7) NEW_TIMEZONE="Asia/Tokyo" ;;
            9) 
                echo "Enter timezone (e.g., America/New_York, Europe/Berlin):"
                read -p "Timezone: " NEW_TIMEZONE
                ;;
            *) NEW_TIMEZONE="UTC" ;;
        esac
        
        if [[ -n "$NEW_TIMEZONE" ]] && [[ "$NEW_TIMEZONE" != "$CURRENT_TZ" ]]; then
            echo -e "${YELLOW}Setting timezone to: ${BLUE}$NEW_TIMEZONE${NC}"
            if command -v timedatectl &>/dev/null; then
                timedatectl set-timezone "$NEW_TIMEZONE" 2>/dev/null || {
                    echo -e "${RED}Failed to set timezone with timedatectl${NC}"
                    echo "You may need to set it manually after setup"
                }
            else
                echo "$NEW_TIMEZONE" > /etc/timezone 2>/dev/null || {
                    echo -e "${RED}Failed to set timezone${NC}"
                    echo "You may need to set it manually after setup"
                }
            fi
            echo "New time: $(date)"
        fi
    else
        echo -e "${GREEN}Keeping current timezone: $CURRENT_TZ${NC}"
    fi
else
    echo -e "\n${GREEN}Using preset timezone configuration${NC}"
fi
echo ""

# Ask about secret storage method (unless already set via environment)
if [[ -z "$SECRET_MODE" ]]; then
    echo -e "${YELLOW}Secret Storage:${NC}"
    echo "How would you like to store notification secrets?"
    echo "  1) Doppler (recommended - centralized secret management)"
    echo "  2) Local file (simpler - secrets stored in /etc/update-notifier/secrets.conf)"
    echo ""
    read -p "Enter choice [1-2] (default: 1): " -n 1 -r SECRET_CHOICE
    echo ""
    if [[ "$SECRET_CHOICE" == "2" ]]; then
        SECRET_MODE="local"
        echo -e "${GREEN}Selected: Local file storage${NC}"
    else
        SECRET_MODE="doppler"
        echo -e "${GREEN}Selected: Doppler${NC}"
    fi
else
    echo -e "\n${GREEN}Using preset secret mode: ${SECRET_MODE}${NC}"
fi

# If using Doppler, ask for service token
if [[ "$SECRET_MODE" == "doppler" ]]; then
    if [[ -z "${DOPPLER_TOKEN:-}" ]]; then
        echo ""
        echo -e "${YELLOW}Doppler Service Token Required:${NC}"
        echo "You need a Doppler service token to allow the notification script to access secrets."
        echo ""
        echo "To create a token:"
        echo "  1. Run: ${BLUE}doppler configs tokens create patch-gremlin-token --max-age 0${NC}"
        echo "  2. Copy the token (starts with dp.st.)"
        echo "  OR visit: https://dashboard.doppler.com"
        echo ""
        read -p "Enter your Doppler service token: " DOPPLER_TOKEN
        if [[ -z "${DOPPLER_TOKEN:-}" ]]; then
            echo -e "${RED}Error: Doppler token is required when using Doppler mode${NC}"
            exit 1
        fi
        # Validate token format
        if [[ ! "${DOPPLER_TOKEN:-}" =~ ^dp\.st\. ]]; then
            echo -e "${YELLOW}Warning: Token doesn't start with 'dp.st.' - it may not be valid${NC}"
        fi
    else
        echo -e "${GREEN}Using preset Doppler token${NC}"
    fi
fi

echo ""

# Load configuration from file if it exists with enhanced validation
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
load_config_safely() {
    local config_file="$1"
    echo "Loading configuration from $config_file"
    
    # Simplified validation: We only source lines that match export pattern
    # This is safe because we filter to ONLY those lines before sourcing
    # Comments with dangerous patterns are automatically ignored
    
    # Check for valid export statements
    if ! grep -q '^[[:space:]]*export[[:space:]]\+[A-Z_][A-Z0-9_]*=' "$config_file"; then
        echo -e "${YELLOW}Warning: config.sh doesn't contain valid export statements${NC}"
        return 1
    fi
    
    # Create temp file with ONLY export lines (this filters out everything else)
    local temp_config
    temp_config=$(mktemp)
    
    # Extract only lines matching the export pattern
    # This automatically excludes comments, blank lines, and non-export commands
    grep '^[[:space:]]*export[[:space:]]\+[A-Z_][A-Z0-9_]*=' "$config_file" > "$temp_config"
    
    # Verify the filtered content doesn't contain dangerous unquoted patterns
    # (already filtered to export lines, so we're checking the values)
    if grep -E 'export[^=]+=.*(\$\(|`|;|&&|\|\|)' "$temp_config" | grep -qv '".*\$.*"'; then
        echo -e "${YELLOW}Warning: Config may contain command substitutions${NC}"
        echo -e "${YELLOW}This is usually safe if values are properly quoted${NC}"
    fi
    
    # shellcheck source=/dev/null
    source "$temp_config"
    rm -f "$temp_config"
    
    echo "Configuration loaded successfully"
}

if [[ -f "$SCRIPT_DIR/config.sh" ]] && [[ -r "$SCRIPT_DIR/config.sh" ]]; then
    load_config_safely "$SCRIPT_DIR/config.sh"
elif [[ -f /etc/update-notifier/config.sh ]] && [[ -r /etc/update-notifier/config.sh ]]; then
    load_config_safely "/etc/update-notifier/config.sh"
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

# If using local file mode, collect secrets now
if [[ "$SECRET_MODE" == "local" ]]; then
    echo -e "${YELLOW}Configure Notification Secrets:${NC}"
    echo "You can configure one or more notification platforms (leave blank to skip):"
    echo ""
    
    # Discord
    read -p "Discord webhook URL (optional): " LOCAL_DISCORD_WEBHOOK
    
    # Teams
    read -p "Microsoft Teams webhook URL (optional): " LOCAL_TEAMS_WEBHOOK
    
    # Slack
    read -p "Slack webhook URL (optional): " LOCAL_SLACK_WEBHOOK
    
    # Matrix - ask which method
    echo ""
    echo -e "${YELLOW}Matrix Configuration:${NC}"
    echo "  1) Skip Matrix"
    echo "  2) Webhook URL"
    echo "  3) Homeserver + Username/Password (recommended)"
    read -p "Enter choice [1-3] (default: 1): " -n 1 -r MATRIX_CHOICE
    echo ""
    
    case "$MATRIX_CHOICE" in
        2)
            read -p "Matrix webhook URL: " LOCAL_MATRIX_WEBHOOK
            ;;
        3)
            read -p "Matrix homeserver (e.g., https://matrix.org): " LOCAL_MATRIX_HOMESERVER
            read -p "Matrix username (e.g., @user:matrix.org): " LOCAL_MATRIX_USERNAME
            read -sp "Matrix password: " LOCAL_MATRIX_PASSWORD
            echo ""
            read -p "Matrix room ID (e.g., !room:matrix.org): " LOCAL_MATRIX_ROOM_ID
            ;;
    esac
    
    # Validate at least one method configured
    if [[ -z "$LOCAL_DISCORD_WEBHOOK" ]] && [[ -z "$LOCAL_TEAMS_WEBHOOK" ]] && [[ -z "$LOCAL_SLACK_WEBHOOK" ]] && [[ -z "$LOCAL_MATRIX_WEBHOOK" ]] && [[ -z "$LOCAL_MATRIX_HOMESERVER" ]]; then
        echo -e "${RED}Error: At least one notification method must be configured${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Secrets collected${NC}"
    echo ""
fi

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
        cp /etc/apt/apt.conf.d/50unattended-upgrades "/etc/apt/apt.conf.d/50unattended-upgrades.backup.$(date +%Y%m%d-%H%M%S)"
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

    # Create auto-upgrades configuration - always enable, schedule controlled by timer
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "2";
EOF

    # Configure apt-daily-upgrade.timer to run at specific time
    mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d/
    
    # Backup existing timer override if it exists
    if [[ -f /etc/systemd/system/apt-daily-upgrade.timer.d/schedule.conf ]]; then
        cp /etc/systemd/system/apt-daily-upgrade.timer.d/schedule.conf \
           "/etc/systemd/system/apt-daily-upgrade.timer.d/schedule.conf.backup.$(date +%Y%m%d-%H%M%S)"
        echo -e "${YELLOW}Backed up existing timer configuration${NC}"
    fi
    
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        cat > /etc/systemd/system/apt-daily-upgrade.timer.d/schedule.conf << EOF
[Timer]
# Override default schedule - run weekly on ${UPDATE_DAY}day at ${UPDATE_TIME}
# Patch Gremlin configuration
OnCalendar=
OnCalendar=${UPDATE_DAY} *-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
EOF
    else
        cat > /etc/systemd/system/apt-daily-upgrade.timer.d/schedule.conf << EOF
[Timer]
# Override default schedule - run daily at ${UPDATE_TIME}
# Patch Gremlin configuration
OnCalendar=
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
EOF
    fi
    
    # Reload systemd to apply timer changes
    systemctl daemon-reload
    systemctl restart apt-daily-upgrade.timer

    echo -e "  ${GREEN}✓${NC} Configured unattended-upgrades for Debian/Ubuntu (${UPDATE_TYPE} updates, ${UPDATE_SCHEDULE} at ${UPDATE_TIME})"
}

install_rhel_updates() {
    echo -e "${YELLOW}Installing dnf-automatic package...${NC}"
    "$PACKAGE_MANAGER" install -y dnf-automatic

    echo -e "${YELLOW}Configuring dnf-automatic...${NC}"
    
    # Backup existing config if it exists
    if [[ -f /etc/dnf/automatic.conf ]]; then
        cp /etc/dnf/automatic.conf "/etc/dnf/automatic.conf.backup.$(date +%Y%m%d-%H%M%S)"
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
    
    # Backup existing timer override if it exists
    if [[ -f /etc/systemd/system/dnf-automatic.timer.d/schedule.conf ]]; then
        cp /etc/systemd/system/dnf-automatic.timer.d/schedule.conf \
           "/etc/systemd/system/dnf-automatic.timer.d/schedule.conf.backup.$(date +%Y%m%d-%H%M%S)"
        echo -e "${YELLOW}Backed up existing timer configuration${NC}"
    fi
    
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        cat > /etc/systemd/system/dnf-automatic.timer.d/schedule.conf << EOF
[Timer]
# Override default schedule - run weekly on ${UPDATE_DAY}day at ${UPDATE_TIME}
# Patch Gremlin configuration
OnCalendar=
OnCalendar=${UPDATE_DAY} *-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
EOF
    else
        cat > /etc/systemd/system/dnf-automatic.timer.d/schedule.conf << EOF
[Timer]
# Override default schedule - run daily at ${UPDATE_TIME}
# Patch Gremlin configuration
OnCalendar=
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=30min
EOF
    fi
    
    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable --now dnf-automatic.timer
    
    echo -e "  ${GREEN}✓${NC} Configured dnf-automatic for RHEL/Fedora/Amazon Linux (${UPDATE_TYPE} updates, ${UPDATE_SCHEDULE} at ${UPDATE_TIME})"
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

# Validate environment
echo -e "\033[0;32m✓ Running as root\033[0m"
echo -e "\033[0;32m✓ OS detected: $OS_ID $OS_VERSION (type: $OS_TYPE)\033[0m"

# Check if Doppler is configured (only if using Doppler mode)
if [[ "$SECRET_MODE" == "doppler" ]]; then
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

# Create secrets file if using local mode
mkdir -p /etc/update-notifier
if [[ "$SECRET_MODE" == "local" ]]; then
    echo -e "${YELLOW}Creating local secrets file...${NC}"
    cat > /etc/update-notifier/secrets.conf << EOF
# Patch Gremlin Local Secrets
# This file contains notification webhook URLs and credentials
# Protect this file: chmod 600 /etc/update-notifier/secrets.conf

SECRET_MODE="local"

# Discord
DISCORD_WEBHOOK="${LOCAL_DISCORD_WEBHOOK}"

# Microsoft Teams
TEAMS_WEBHOOK="${LOCAL_TEAMS_WEBHOOK}"

# Slack
SLACK_WEBHOOK="${LOCAL_SLACK_WEBHOOK}"

# Matrix - Webhook
MATRIX_WEBHOOK="${LOCAL_MATRIX_WEBHOOK}"

# Matrix - API
MATRIX_HOMESERVER="${LOCAL_MATRIX_HOMESERVER}"
MATRIX_USERNAME="${LOCAL_MATRIX_USERNAME}"
MATRIX_PASSWORD="${LOCAL_MATRIX_PASSWORD}"
MATRIX_ROOM_ID="${LOCAL_MATRIX_ROOM_ID}"
EOF
    chmod 600 /etc/update-notifier/secrets.conf
    echo -e "  ${GREEN}✓${NC} Created /etc/update-notifier/secrets.conf"
fi

# Copy config file to system location if it exists (for Doppler mode)
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    echo -e "${YELLOW}Installing configuration file...${NC}"
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

# Build environment variables based on mode with proper escaping
if [[ "$SECRET_MODE" == "doppler" ]]; then
    # Escape special characters for systemd
    ESCAPED_TOKEN=$(printf '%s\n' "${DOPPLER_TOKEN:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_DISCORD=$(printf '%s\n' "${DOPPLER_DISCORD_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_TEAMS=$(printf '%s\n' "${DOPPLER_TEAMS_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_SLACK=$(printf '%s\n' "${DOPPLER_SLACK_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_MATRIX=$(printf '%s\n' "${DOPPLER_MATRIX_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_HOMESERVER=$(printf '%s\n' "${DOPPLER_MATRIX_HOMESERVER_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_USERNAME=$(printf '%s\n' "${DOPPLER_MATRIX_USERNAME_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_PASSWORD=$(printf '%s\n' "${DOPPLER_MATRIX_PASSWORD_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    ESCAPED_ROOM=$(printf '%s\n' "${DOPPLER_MATRIX_ROOM_ID_SECRET:-}" | sed 's/[\\\"]/\\&/g')
    
    SERVICE_ENV="Environment=\"DOPPLER_TOKEN=$ESCAPED_TOKEN\"
Environment=\"DOPPLER_DISCORD_SECRET=$ESCAPED_DISCORD\"
Environment=\"DOPPLER_TEAMS_SECRET=$ESCAPED_TEAMS\"
Environment=\"DOPPLER_SLACK_SECRET=$ESCAPED_SLACK\"
Environment=\"DOPPLER_MATRIX_SECRET=$ESCAPED_MATRIX\"
Environment=\"DOPPLER_MATRIX_HOMESERVER_SECRET=$ESCAPED_HOMESERVER\"
Environment=\"DOPPLER_MATRIX_USERNAME_SECRET=$ESCAPED_USERNAME\"
Environment=\"DOPPLER_MATRIX_PASSWORD_SECRET=$ESCAPED_PASSWORD\"
Environment=\"DOPPLER_MATRIX_ROOM_ID_SECRET=$ESCAPED_ROOM\""
else
    SERVICE_ENV="Environment=\"SECRET_MODE=local\""
fi

cat > /etc/systemd/system/update-notifier.service << EOF
[Unit]
Description=Update Notification Service
After=apt-daily-upgrade.service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
$SERVICE_ENV
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
    
    # Build hook environment based on mode
    if [[ "$SECRET_MODE" == "doppler" ]]; then
        HOOK_ENV="DOPPLER_TOKEN='$DOPPLER_TOKEN' DOPPLER_DISCORD_SECRET='$DOPPLER_DISCORD_SECRET' DOPPLER_TEAMS_SECRET='$DOPPLER_TEAMS_SECRET' DOPPLER_SLACK_SECRET='$DOPPLER_SLACK_SECRET' DOPPLER_MATRIX_SECRET='$DOPPLER_MATRIX_SECRET' DOPPLER_MATRIX_HOMESERVER_SECRET='$DOPPLER_MATRIX_HOMESERVER_SECRET' DOPPLER_MATRIX_USERNAME_SECRET='$DOPPLER_MATRIX_USERNAME_SECRET' DOPPLER_MATRIX_PASSWORD_SECRET='$DOPPLER_MATRIX_PASSWORD_SECRET' DOPPLER_MATRIX_ROOM_ID_SECRET='$DOPPLER_MATRIX_ROOM_ID_SECRET'"
    else
        HOOK_ENV="SECRET_MODE='local'"
    fi
    
    cat > /etc/apt/apt.conf.d/99patch-gremlin-notification << EOF
// Run Patch Gremlin notification script after unattended-upgrades completes
Dpkg::Post-Invoke {
    "if [ -x /usr/local/bin/update-notifier.sh ]; then $HOOK_ENV /usr/local/bin/update-notifier.sh || true; fi";
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
    
    # Build environment variables based on mode with proper escaping
    if [[ "$SECRET_MODE" == "doppler" ]]; then
        # Use already escaped variables from above
        DNF_ENV="Environment=\"DOPPLER_TOKEN=$ESCAPED_TOKEN\"
Environment=\"DOPPLER_DISCORD_SECRET=$ESCAPED_DISCORD\"
Environment=\"DOPPLER_TEAMS_SECRET=$ESCAPED_TEAMS\"
Environment=\"DOPPLER_SLACK_SECRET=$ESCAPED_SLACK\"
Environment=\"DOPPLER_MATRIX_SECRET=$ESCAPED_MATRIX\"
Environment=\"DOPPLER_MATRIX_HOMESERVER_SECRET=$ESCAPED_HOMESERVER\"
Environment=\"DOPPLER_MATRIX_USERNAME_SECRET=$ESCAPED_USERNAME\"
Environment=\"DOPPLER_MATRIX_PASSWORD_SECRET=$ESCAPED_PASSWORD\"
Environment=\"DOPPLER_MATRIX_ROOM_ID_SECRET=$ESCAPED_ROOM\""
    else
        DNF_ENV="Environment=\"SECRET_MODE=local\""
    fi
    
    cat > /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf << EOF
[Service]
ExecStartPost=/usr/local/bin/patch-gremlin-dnf-hook.sh
$DNF_ENV
EOF
    echo -e "  ${GREEN}✓${NC} Created DNF post-upgrade hook"
fi

# Reload systemd
systemctl daemon-reload

# Enable and start the notification timer
echo -e "\033[1;33mEnabling and starting timers...\033[0m"
systemctl enable update-notifier.timer
systemctl start update-notifier.timer
echo -e "\033[0;32m✓ Notification timer enabled and started\033[0m"

# Final validation
echo -e "\033[1;33mPerforming final validation...\033[0m"

# Test notification script
if [[ -x /usr/local/bin/update-notifier.sh ]]; then
    if PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh &>/dev/null; then
        echo -e "\033[0;32m✓ Notification script test passed\033[0m"
    else
        echo -e "\033[1;33m⚠ Notification script test failed (may need secrets configured)\033[0m"
    fi
fi

# Check timer status
if systemctl is-enabled update-notifier.timer &>/dev/null; then
    echo -e "\033[0;32m✓ Timer enabled and scheduled\033[0m"
    NEXT_RUN=$(systemctl list-timers update-notifier.timer --no-pager 2>/dev/null | grep update-notifier | awk '{print $1" "$2}' || echo "")
    [[ -n "$NEXT_RUN" ]] && echo -e "  Next run: \033[0;34m$NEXT_RUN\033[0m"
else
    echo -e "\033[1;33m⚠ Timer not enabled\033[0m"
fi

echo -e "\033[0;32mConfiguration complete!\033[0m"
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
echo ""
echo -e "\033[0;32m🎉 Patch Gremlin installation complete!\033[0m"
echo ""
echo -e "\033[0;34mWhat happens next:\033[0m"
echo "• System will automatically install $UPDATE_TYPE updates $UPDATE_SCHEDULE"
echo "• Notifications will be sent to your configured platforms"
echo "• Logs are available via: journalctl -t patch-gremlin"
echo ""
echo -e "\033[0;34mQuick commands:\033[0m"
echo "• Test notification: sudo /usr/local/bin/update-notifier.sh"
echo "• Check health: sudo /usr/local/bin/patch-gremlin-health-check.sh"
echo "• View logs: sudo journalctl -t patch-gremlin --since '1 day ago'"
echo "• Check timer: sudo systemctl list-timers update-notifier*"
