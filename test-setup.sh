#!/bin/bash

# Test script for update-notifier setup
# This script helps verify that everything is configured correctly

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Update Notifier Configuration Test ===${NC}\n"

# Get configured secret names
DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
DOPPLER_MATRIX_SECRET="${DOPPLER_MATRIX_SECRET:-UPDATE_NOTIFIER_MATRIX_WEBHOOK}"
DOPPLER_MATRIX_HOMESERVER_SECRET="${DOPPLER_MATRIX_HOMESERVER_SECRET:-UPDATE_NOTIFIER_MATRIX_HOMESERVER}"
DOPPLER_MATRIX_USERNAME_SECRET="${DOPPLER_MATRIX_USERNAME_SECRET:-UPDATE_NOTIFIER_MATRIX_USERNAME}"
DOPPLER_MATRIX_PASSWORD_SECRET="${DOPPLER_MATRIX_PASSWORD_SECRET:-UPDATE_NOTIFIER_MATRIX_PASSWORD}"
DOPPLER_MATRIX_ROOM_ID_SECRET="${DOPPLER_MATRIX_ROOM_ID_SECRET:-UPDATE_NOTIFIER_MATRIX_ROOM_ID}"

echo -e "${YELLOW}Configured Doppler Secret Names:${NC}"
echo -e "  Discord Webhook:     ${BLUE}$DOPPLER_DISCORD_SECRET${NC}"
echo -e "  Matrix Webhook:      ${BLUE}$DOPPLER_MATRIX_SECRET${NC}"
echo -e "  Matrix Homeserver:   ${BLUE}$DOPPLER_MATRIX_HOMESERVER_SECRET${NC}"
echo -e "  Matrix Username:     ${BLUE}$DOPPLER_MATRIX_USERNAME_SECRET${NC}"
echo -e "  Matrix Password:     ${BLUE}$DOPPLER_MATRIX_PASSWORD_SECRET${NC}"
echo -e "  Matrix Room ID:      ${BLUE}$DOPPLER_MATRIX_ROOM_ID_SECRET${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Note: Not running as root. Some checks will be skipped.${NC}"
   echo -e "Run with: ${BLUE}sudo $0${NC} for complete testing\n"
   AS_ROOT=false
else
   AS_ROOT=true
fi

# Check if Doppler CLI is installed
echo -e "${YELLOW}Checking Doppler CLI...${NC}"
if command -v doppler &> /dev/null; then
    DOPPLER_VERSION=$(doppler --version 2>&1 | head -n1)
    echo -e "  ${GREEN}✓${NC} Doppler CLI installed: $DOPPLER_VERSION"
else
    echo -e "  ${RED}✗${NC} Doppler CLI not found"
    echo -e "    Install: ${BLUE}curl -Ls https://cli.doppler.com/install.sh | sh${NC}"
    exit 1
fi

# Check if logged in to Doppler (check for current user or root)
echo -e "\n${YELLOW}Checking Doppler authentication...${NC}"
if [[ $AS_ROOT == true ]]; then
    # Running as root, check root's Doppler config
    # Check if 'doppler me' returns successfully (exit code 0)
    if doppler me &>/dev/null; then
        DOPPLER_NAME=$(doppler me 2>/dev/null | grep -E "^\│" | head -2 | tail -1 | awk -F'│' '{print $2}' | xargs || echo "unknown")
        echo -e "  ${GREEN}✓${NC} Logged in as root user: $DOPPLER_NAME"
    else
        echo -e "  ${RED}✗${NC} Not logged in to Doppler as root"
        echo -e "    Run: ${BLUE}sudo doppler login${NC}"
        exit 1
    fi
else
    # Running as regular user
    if doppler me &>/dev/null; then
        DOPPLER_NAME=$(doppler me 2>/dev/null | grep -E "^\│" | head -2 | tail -1 | awk -F'│' '{print $2}' | xargs || echo "unknown")
        echo -e "  ${GREEN}✓${NC} Logged in as user: $DOPPLER_NAME"
        echo -e "  ${YELLOW}⚠${NC}  Note: Script runs as root, so root also needs to be logged in"
        echo -e "    Run: ${BLUE}sudo doppler login${NC} to configure for root user"
    else
        echo -e "  ${RED}✗${NC} Not logged in to Doppler"
        echo -e "    Run: ${BLUE}doppler login${NC}"
        exit 1
    fi
fi

# Check Doppler setup (project configuration)
echo -e "\n${YELLOW}Checking Doppler configuration...${NC}"
if doppler configure get 2>/dev/null | grep -q project; then
    DOPPLER_PROJECT=$(doppler configure get project --plain 2>/dev/null || echo "unknown")
    DOPPLER_CONFIG=$(doppler configure get config --plain 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓${NC} Doppler project configured"
    echo -e "    Project: $DOPPLER_PROJECT"
    echo -e "    Config:  $DOPPLER_CONFIG"
else
    echo -e "  ${RED}✗${NC} Doppler not configured for this directory"
    if [[ $AS_ROOT == true ]]; then
        echo -e "    Run: ${BLUE}doppler setup${NC}"
    else
        echo -e "    Run: ${BLUE}sudo doppler setup${NC} (must configure as root)"
    fi
    exit 1
fi

# Check if logged in to Doppler
echo -e "\n${YELLOW}Checking Doppler authentication...${NC}"
if doppler me 2>/dev/null | grep -q email; then
    DOPPLER_EMAIL=$(doppler me --json 2>/dev/null | grep -oP '"email":\s*"\K[^"]+' || echo "unknown")
    echo -e "  ${GREEN}✓${NC} Logged in as: $DOPPLER_EMAIL"
else
    echo -e "  ${RED}✗${NC} Not logged in to Doppler"
    echo -e "    Run: ${BLUE}doppler login${NC}"
    exit 1
fi

# Check Doppler setup
echo -e "\n${YELLOW}Checking Doppler configuration...${NC}"
if doppler configure get 2>/dev/null | grep -q project; then
    DOPPLER_PROJECT=$(doppler configure get project --plain 2>/dev/null || echo "unknown")
    DOPPLER_CONFIG=$(doppler configure get config --plain 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓${NC} Doppler project configured"
    echo -e "    Project: $DOPPLER_PROJECT"
    echo -e "    Config:  $DOPPLER_CONFIG"
else
    echo -e "  ${RED}✗${NC} Doppler not configured for this directory"
    echo -e "    Run: ${BLUE}doppler setup${NC}"
    exit 1
fi

# Check for webhook secrets
echo -e "\n${YELLOW}Checking notification secrets in Doppler...${NC}"
DISCORD_FOUND=false
MATRIX_WEBHOOK_FOUND=false
MATRIX_API_FOUND=false

# Check Discord
if doppler secrets get "$DOPPLER_DISCORD_SECRET" --plain &>/dev/null; then
    DISCORD_URL=$(doppler secrets get "$DOPPLER_DISCORD_SECRET" --plain 2>/dev/null)
    if [[ -n "$DISCORD_URL" ]]; then
        echo -e "  ${GREEN}✓${NC} Discord webhook found: ${BLUE}$DOPPLER_DISCORD_SECRET${NC}"
        echo -e "    URL: ${DISCORD_URL:0:50}..."
        DISCORD_FOUND=true
    fi
else
    echo -e "  ${YELLOW}○${NC} Discord webhook not found: ${BLUE}$DOPPLER_DISCORD_SECRET${NC}"
fi

# Check Matrix webhook method
if doppler secrets get "$DOPPLER_MATRIX_SECRET" --plain &>/dev/null; then
    MATRIX_URL=$(doppler secrets get "$DOPPLER_MATRIX_SECRET" --plain 2>/dev/null)
    if [[ -n "$MATRIX_URL" ]]; then
        echo -e "  ${GREEN}✓${NC} Matrix webhook found: ${BLUE}$DOPPLER_MATRIX_SECRET${NC}"
        echo -e "    URL: ${MATRIX_URL:0:50}..."
        MATRIX_WEBHOOK_FOUND=true
    fi
else
    echo -e "  ${YELLOW}○${NC} Matrix webhook not found: ${BLUE}$DOPPLER_MATRIX_SECRET${NC}"
fi

# Check Matrix API method
MATRIX_HOMESERVER_SET=false
MATRIX_USERNAME_SET=false
MATRIX_PASSWORD_SET=false
MATRIX_ROOM_ID_SET=false

if doppler secrets get "$DOPPLER_MATRIX_HOMESERVER_SECRET" --plain &>/dev/null; then
    HOMESERVER=$(doppler secrets get "$DOPPLER_MATRIX_HOMESERVER_SECRET" --plain 2>/dev/null)
    if [[ -n "$HOMESERVER" ]]; then
        echo -e "  ${GREEN}✓${NC} Matrix homeserver found: ${BLUE}$DOPPLER_MATRIX_HOMESERVER_SECRET${NC}"
        echo -e "    URL: $HOMESERVER"
        MATRIX_HOMESERVER_SET=true
    fi
fi

if doppler secrets get "$DOPPLER_MATRIX_USERNAME_SECRET" --plain &>/dev/null; then
    USERNAME=$(doppler secrets get "$DOPPLER_MATRIX_USERNAME_SECRET" --plain 2>/dev/null)
    if [[ -n "$USERNAME" ]]; then
        echo -e "  ${GREEN}✓${NC} Matrix username found: ${BLUE}$DOPPLER_MATRIX_USERNAME_SECRET${NC}"
        echo -e "    User: $USERNAME"
        MATRIX_USERNAME_SET=true
    fi
fi

if doppler secrets get "$DOPPLER_MATRIX_PASSWORD_SECRET" --plain &>/dev/null; then
    PASSWORD=$(doppler secrets get "$DOPPLER_MATRIX_PASSWORD_SECRET" --plain 2>/dev/null)
    if [[ -n "$PASSWORD" ]]; then
        echo -e "  ${GREEN}✓${NC} Matrix password found: ${BLUE}$DOPPLER_MATRIX_PASSWORD_SECRET${NC}"
        echo -e "    Password: ********"
        MATRIX_PASSWORD_SET=true
    fi
fi

if doppler secrets get "$DOPPLER_MATRIX_ROOM_ID_SECRET" --plain &>/dev/null; then
    ROOM_ID=$(doppler secrets get "$DOPPLER_MATRIX_ROOM_ID_SECRET" --plain 2>/dev/null)
    if [[ -n "$ROOM_ID" ]]; then
        echo -e "  ${GREEN}✓${NC} Matrix room ID found: ${BLUE}$DOPPLER_MATRIX_ROOM_ID_SECRET${NC}"
        echo -e "    Room: $ROOM_ID"
        MATRIX_ROOM_ID_SET=true
    fi
fi

# Determine if Matrix API is fully configured
if [[ "$MATRIX_HOMESERVER_SET" == true ]] && [[ "$MATRIX_USERNAME_SET" == true ]] && [[ "$MATRIX_PASSWORD_SET" == true ]] && [[ "$MATRIX_ROOM_ID_SET" == true ]]; then
    echo -e "  ${GREEN}✓${NC} Matrix API method fully configured!"
    MATRIX_API_FOUND=true
elif [[ "$MATRIX_HOMESERVER_SET" == true ]] || [[ "$MATRIX_USERNAME_SET" == true ]] || [[ "$MATRIX_PASSWORD_SET" == true ]] || [[ "$MATRIX_ROOM_ID_SET" == true ]]; then
    echo -e "  ${YELLOW}⚠${NC}  Matrix API partially configured (need all 4: homeserver, username, password, room ID)"
fi

MATRIX_FOUND=$([[ "$MATRIX_WEBHOOK_FOUND" == true ]] || [[ "$MATRIX_API_FOUND" == true ]] && echo "true" || echo "false")

if [[ "$DISCORD_FOUND" == false ]] && [[ "$MATRIX_FOUND" == false ]]; then
    echo -e "\n${RED}✗ No notification methods configured!${NC}"
    echo -e "Add at least one notification method:"
    echo -e "  ${BLUE}For Discord:${NC}"
    echo -e "    doppler secrets set $DOPPLER_DISCORD_SECRET='https://discord.com/...'"
    echo -e "  ${BLUE}For Matrix (webhook):${NC}"
    echo -e "    doppler secrets set $DOPPLER_MATRIX_SECRET='https://matrix.example.org/...'"
    echo -e "  ${BLUE}For Matrix (username/password):${NC}"
    echo -e "    doppler secrets set $DOPPLER_MATRIX_HOMESERVER_SECRET='https://matrix.org'"
    echo -e "    doppler secrets set $DOPPLER_MATRIX_USERNAME_SECRET='@user:matrix.org'"
    echo -e "    doppler secrets set $DOPPLER_MATRIX_PASSWORD_SECRET='your_password'"
    echo -e "    doppler secrets set $DOPPLER_MATRIX_ROOM_ID_SECRET='!roomid:matrix.org'"
fi

if [[ "$AS_ROOT" == true ]]; then
    # Check if unattended-upgrades is installed
    echo -e "\n${YELLOW}Checking unattended-upgrades...${NC}"
    if dpkg -l | grep -q unattended-upgrades; then
        echo -e "  ${GREEN}✓${NC} unattended-upgrades package installed"
    else
        echo -e "  ${YELLOW}○${NC} unattended-upgrades not installed"
        echo -e "    Run: ${BLUE}sudo ./setup-unattended-upgrades.sh${NC}"
    fi

    # Check if notifier script is installed
    echo -e "\n${YELLOW}Checking notification script...${NC}"
    if [[ -x /usr/local/bin/update-notifier.sh ]]; then
        echo -e "  ${GREEN}✓${NC} Notification script installed"
    else
        echo -e "  ${YELLOW}○${NC} Notification script not installed at /usr/local/bin/update-notifier.sh"
        echo -e "    Run: ${BLUE}sudo ./setup-unattended-upgrades.sh${NC}"
    fi

    # Check systemd service
    echo -e "\n${YELLOW}Checking systemd service...${NC}"
    if [[ -f /etc/systemd/system/update-notifier-discord.service ]]; then
        echo -e "  ${GREEN}✓${NC} Systemd service file exists"
        
        # Check if environment variables are set in service
        if grep -q "DOPPLER_DISCORD_SECRET" /etc/systemd/system/update-notifier-discord.service; then
            echo -e "  ${GREEN}✓${NC} Service configured with custom secret names"
        fi
    else
        echo -e "  ${YELLOW}○${NC} Systemd service not installed"
    fi

    # Check APT hook
    echo -e "\n${YELLOW}Checking APT post-upgrade hook...${NC}"
    if [[ -f /etc/apt/apt.conf.d/99discord-notification ]]; then
        echo -e "  ${GREEN}✓${NC} APT hook file exists"
    else
        echo -e "  ${YELLOW}○${NC} APT hook not installed"
    fi
fi

# Summary
echo -e "\n${BLUE}=== Summary ===${NC}"
if [[ "$DISCORD_FOUND" == true ]] || [[ "$MATRIX_FOUND" == true ]]; then
    echo -e "${GREEN}✓ Basic configuration looks good!${NC}\n"
    
    echo -e "${YELLOW}Next steps:${NC}"
    if [[ "$AS_ROOT" == false ]]; then
        echo -e "1. Run this test as root: ${BLUE}sudo $0${NC}"
    fi
    
    if [[ ! -x /usr/local/bin/update-notifier.sh ]]; then
        echo -e "2. Run setup script: ${BLUE}sudo ./setup-unattended-upgrades.sh${NC}"
    fi
    
    echo -e "3. Test notifications: ${BLUE}sudo /usr/local/bin/update-notifier.sh${NC}"
else
    echo -e "${RED}Configuration incomplete${NC}\n"
    echo -e "Please add at least one webhook secret to Doppler:"
    echo -e "  ${BLUE}doppler secrets set $DOPPLER_DISCORD_SECRET='YOUR_DISCORD_WEBHOOK'${NC}"
    echo -e "  ${BLUE}doppler secrets set $DOPPLER_MATRIX_SECRET='YOUR_MATRIX_WEBHOOK'${NC}"
fi
