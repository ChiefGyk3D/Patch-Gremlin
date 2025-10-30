#!/bin/bash

# Patch Gremlin - Multi-Platform Update Notifier
# Sends system update notifications to Discord and/or Matrix
# Supports both Doppler and local file storage for secrets
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration defaults (can be overridden by environment)
MAX_LOG_LINES="${PATCH_GREMLIN_MAX_LOG_LINES:-50}"
RETRY_COUNT="${PATCH_GREMLIN_RETRY_COUNT:-3}"
RETRY_DELAY="${PATCH_GREMLIN_RETRY_DELAY:-2}"
CURL_TIMEOUT="${PATCH_GREMLIN_CURL_TIMEOUT:-30}"
DRY_RUN="${PATCH_GREMLIN_DRY_RUN:-false}"

# Logging function
log() {
    # Always log to syslog
    logger -t "patch-gremlin" "$*" 2>/dev/null || true
    
    # Only echo to stderr if not running via systemd (interactive mode)
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
    fi
}

# Validate webhook URL format
validate_webhook() {
    local url="$1" platform="$2"
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "WARNING: $platform webhook URL may be invalid: $url"
        return 1
    fi
    # Additional validation for common webhook patterns
    case "$platform" in
        "Discord")
            if [[ ! "$url" =~ discord\.com/api/webhooks/ ]]; then
                log "WARNING: $platform URL doesn't match expected Discord webhook pattern"
            fi
            ;;
        "Teams")
            if [[ ! "$url" =~ outlook\.office\.com/webhook/ ]]; then
                log "WARNING: $platform URL doesn't match expected Teams webhook pattern"
            fi
            ;;
        "Slack")
            if [[ ! "$url" =~ hooks\.slack\.com/services/ ]]; then
                log "WARNING: $platform URL doesn't match expected Slack webhook pattern"
            fi
            ;;
    esac
    return 0
}

# Comprehensive validation function
validate_environment() {
    local errors=0
    
    # Check required commands
    for cmd in curl grep awk sed tail; do
        if ! command -v "$cmd" &>/dev/null; then
            log "ERROR: Required command not found: $cmd"
            ((errors++))
        fi
    done
    
    # Validate OS detection
    if [[ "$OS_TYPE" != "debian" ]] && [[ "$OS_TYPE" != "rhel" ]]; then
        log "ERROR: Unsupported OS type: $OS_TYPE"
        ((errors++))
    fi
    
    # Check log file permissions
    if [[ -f "$LOG_FILE" ]] && [[ ! -r "$LOG_FILE" ]]; then
        log "ERROR: Cannot read log file: $LOG_FILE"
        ((errors++))
    fi
    
    return $errors
}

# Initialize SECRET_MODE with default
SECRET_MODE="${SECRET_MODE:-doppler}"

# Load configuration from file if it exists first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.sh" ]] && [[ -r "$SCRIPT_DIR/config.sh" ]]; then
    # Basic validation: check file is not world-writable
    if [[ ! -w "$SCRIPT_DIR/config.sh" ]] || [[ "$(stat -c %a "$SCRIPT_DIR/config.sh" 2>/dev/null)" != *[2367] ]]; then
        source "$SCRIPT_DIR/config.sh"
    else
        log "WARNING: Skipping $SCRIPT_DIR/config.sh - file has unsafe permissions"
    fi
elif [[ -f /etc/update-notifier/config.sh ]] && [[ -r /etc/update-notifier/config.sh ]]; then
    # Basic validation: check file is not world-writable
    if [[ "$(stat -c %a /etc/update-notifier/config.sh 2>/dev/null)" != *[2367] ]]; then
        source /etc/update-notifier/config.sh
    else
        log "WARNING: Skipping /etc/update-notifier/config.sh - file has unsafe permissions"
    fi
fi

# Check if using local secrets file and override mode
if [[ -f /etc/update-notifier/secrets.conf ]] && [[ -r /etc/update-notifier/secrets.conf ]]; then
    # Basic validation: check file is not world-writable
    if [[ "$(stat -c %a /etc/update-notifier/secrets.conf 2>/dev/null)" != *[2367] ]]; then
        source /etc/update-notifier/secrets.conf
        SECRET_MODE="local"
    else
        log "WARNING: Skipping /etc/update-notifier/secrets.conf - file has unsafe permissions"
    fi
fi

# Configuration - Customize these Doppler secret names to avoid conflicts
DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
DOPPLER_MATRIX_SECRET="${DOPPLER_MATRIX_SECRET:-UPDATE_NOTIFIER_MATRIX_WEBHOOK}"
DOPPLER_MATRIX_HOMESERVER_SECRET="${DOPPLER_MATRIX_HOMESERVER_SECRET:-UPDATE_NOTIFIER_MATRIX_HOMESERVER}"
DOPPLER_MATRIX_USERNAME_SECRET="${DOPPLER_MATRIX_USERNAME_SECRET:-UPDATE_NOTIFIER_MATRIX_USERNAME}"
DOPPLER_MATRIX_PASSWORD_SECRET="${DOPPLER_MATRIX_PASSWORD_SECRET:-UPDATE_NOTIFIER_MATRIX_PASSWORD}"
DOPPLER_MATRIX_ROOM_ID_SECRET="${DOPPLER_MATRIX_ROOM_ID_SECRET:-UPDATE_NOTIFIER_MATRIX_ROOM_ID}"
DOPPLER_TEAMS_SECRET="${DOPPLER_TEAMS_SECRET:-UPDATE_NOTIFIER_TEAMS_WEBHOOK}"
DOPPLER_SLACK_SECRET="${DOPPLER_SLACK_SECRET:-UPDATE_NOTIFIER_SLACK_WEBHOOK}"

# Configuration
# Auto-detect OS type and log file location
if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    # Debian/Ubuntu
    OS_TYPE="debian"
    LOG_FILE="/var/log/unattended-upgrades/unattended-upgrades.log"
elif [[ -f /var/log/dnf.log ]]; then
    # RHEL/Fedora/Amazon Linux  
    OS_TYPE="rhel"
    LOG_FILE="/var/log/dnf.log"
elif [[ -f /var/log/yum.log ]]; then
    # Older RHEL/CentOS
    OS_TYPE="rhel"
    LOG_FILE="/var/log/yum.log"
else
    # Fallback - try to detect from /etc/os-release
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" =~ ^(debian|ubuntu)$ ]] || [[ "$ID_LIKE" =~ debian ]]; then
            OS_TYPE="debian"
            LOG_FILE="/var/log/unattended-upgrades/unattended-upgrades.log"
        else
            OS_TYPE="rhel"
            LOG_FILE="/var/log/dnf.log"
        fi
    else
        OS_TYPE="debian"
        LOG_FILE="/var/log/unattended-upgrades/unattended-upgrades.log"
    fi
fi
HOSTNAME=$(hostname)
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S %Z')
LAST_RUN_UTC=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')

# Validate environment after OS_TYPE and LOG_FILE are set
if ! validate_environment; then
    log "ERROR: Environment validation failed"
    exit 1
fi

# Retrieve secrets based on mode
if [[ "$SECRET_MODE" == "local" ]]; then
    # Secrets already loaded from /etc/update-notifier/secrets.conf
    DISCORD_WEBHOOK="${DISCORD_WEBHOOK}"
    TEAMS_WEBHOOK="${TEAMS_WEBHOOK}"
    SLACK_WEBHOOK="${SLACK_WEBHOOK}"
    MATRIX_WEBHOOK="${MATRIX_WEBHOOK}"
    MATRIX_HOMESERVER="${MATRIX_HOMESERVER}"
    MATRIX_USERNAME="${MATRIX_USERNAME}"
    MATRIX_PASSWORD="${MATRIX_PASSWORD}"
    MATRIX_ROOM_ID="${MATRIX_ROOM_ID}"
else
    # Check if Doppler CLI is installed
    if ! command -v doppler &> /dev/null; then
        log "ERROR: Doppler CLI is not installed. Please install it first."
        log "Visit: https://docs.doppler.com/docs/install-cli"
        exit 1
    fi
    
    # Test Doppler connectivity with better error handling
    DOPPLER_ERROR=$(doppler me 2>&1)
    if [[ $? -ne 0 ]]; then
        log "ERROR: Doppler authentication failed. Run 'doppler login'"
        log "Doppler error: $(echo "$DOPPLER_ERROR" | head -1 | sed 's/[Tt]oken/[REDACTED]/g')"
        exit 1
    fi
    
    # Retrieve webhook URLs and Matrix credentials from Doppler with error handling
    DISCORD_WEBHOOK=$(doppler secrets get "$DOPPLER_DISCORD_SECRET" --plain 2>/dev/null || true)
    TEAMS_WEBHOOK=$(doppler secrets get "$DOPPLER_TEAMS_SECRET" --plain 2>/dev/null || true)
    SLACK_WEBHOOK=$(doppler secrets get "$DOPPLER_SLACK_SECRET" --plain 2>/dev/null || true)

    # Matrix can use either webhooks OR homeserver + username + password + room ID
    MATRIX_WEBHOOK=$(doppler secrets get "$DOPPLER_MATRIX_SECRET" --plain 2>/dev/null || true)
    MATRIX_HOMESERVER=$(doppler secrets get "$DOPPLER_MATRIX_HOMESERVER_SECRET" --plain 2>/dev/null || true)
    MATRIX_USERNAME=$(doppler secrets get "$DOPPLER_MATRIX_USERNAME_SECRET" --plain 2>/dev/null || true)
    MATRIX_PASSWORD=$(doppler secrets get "$DOPPLER_MATRIX_PASSWORD_SECRET" --plain 2>/dev/null || true)
    MATRIX_ROOM_ID=$(doppler secrets get "$DOPPLER_MATRIX_ROOM_ID_SECRET" --plain 2>/dev/null || true)
    
    # Log if no secrets were retrieved (without exposing values)
    if [[ -z "$DISCORD_WEBHOOK" && -z "$TEAMS_WEBHOOK" && -z "$SLACK_WEBHOOK" && -z "$MATRIX_WEBHOOK" && -z "$MATRIX_HOMESERVER" ]]; then
        log "WARNING: No notification secrets found in Doppler. Check secret names and permissions."
    fi
fi

# Determine Matrix configuration method
MATRIX_CONFIGURED=false
MATRIX_USE_API=false

if [[ -n "$MATRIX_WEBHOOK" ]]; then
    MATRIX_CONFIGURED=true
    MATRIX_USE_API=false
elif [[ -n "$MATRIX_HOMESERVER" ]] && [[ -n "$MATRIX_USERNAME" ]] && [[ -n "$MATRIX_PASSWORD" ]] && [[ -n "$MATRIX_ROOM_ID" ]]; then
    MATRIX_CONFIGURED=true
    MATRIX_USE_API=true
fi

# Check if at least one notification method is configured
if [[ -z "$DISCORD_WEBHOOK" ]] && [[ -z "$TEAMS_WEBHOOK" ]] && [[ -z "$SLACK_WEBHOOK" ]] && [[ "$MATRIX_CONFIGURED" == false ]]; then
    log "ERROR: No notification methods configured."
    echo ""
    if [[ "$SECRET_MODE" == "local" ]]; then
        echo "Using local file storage mode."
        echo "Secrets should be configured in: /etc/update-notifier/secrets.conf"
        echo "Re-run the setup script to reconfigure."
    else
        echo "Using Doppler mode."
        echo "Make sure you have:"
        echo "1. Run 'doppler login' to authenticate"
        echo "2. Run 'doppler setup' in your project directory"
        echo "3. Added at least one notification method:"
        echo ""
        echo "   For Discord:"
        echo "   - $DOPPLER_DISCORD_SECRET (webhook URL)"
        echo ""
        echo "   For Microsoft Teams:"
        echo "   - $DOPPLER_TEAMS_SECRET (webhook URL)"
        echo ""
        echo "   For Slack:"
        echo "   - $DOPPLER_SLACK_SECRET (webhook URL)"
        echo ""
        echo "   For Matrix (choose one method):"
        echo "   - $DOPPLER_MATRIX_SECRET (webhook URL) OR"
        echo "   - $DOPPLER_MATRIX_HOMESERVER_SECRET (e.g., https://matrix.org)"
        echo "   - $DOPPLER_MATRIX_USERNAME_SECRET (e.g., @user:matrix.org)"
        echo "   - $DOPPLER_MATRIX_PASSWORD_SECRET (Matrix account password)"
        echo "   - $DOPPLER_MATRIX_ROOM_ID_SECRET (e.g., !roomid:matrix.org)"
        echo ""
        echo "You can customize the secret names by setting environment variables in config.sh"
    fi
    exit 1
fi

# Check for available updates (including non-security updates)
AVAILABLE_UPDATES=0
AVAILABLE_PACKAGES=""
if [[ "$OS_TYPE" == "debian" ]]; then
    # Run apt list --upgradable to check for any available updates
    AVAILABLE_PACKAGES=$(apt list --upgradable 2>/dev/null | grep "upgradable" | awk -F'/' '{print $1}' | head -n 10 | tr '\n' ', ' | sed 's/, $//')
    AVAILABLE_UPDATES=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
    if [[ "$AVAILABLE_UPDATES" -gt 0 ]]; then
        log "INFO: Found $AVAILABLE_UPDATES upgradable packages (including non-security updates): $AVAILABLE_PACKAGES"
    fi
elif [[ "$OS_TYPE" == "rhel" ]]; then
    # Check for available updates on RHEL-based systems
    AVAILABLE_PACKAGES=$(dnf check-update -q 2>/dev/null | grep -v "^$" | awk '{print $1}' | head -n 10 | tr '\n' ', ' | sed 's/, $//')
    AVAILABLE_UPDATES=$(dnf check-update -q 2>/dev/null | grep -v "^$" | wc -l || echo "0")
    if [[ "$AVAILABLE_UPDATES" -gt 0 ]]; then
        log "INFO: Found $AVAILABLE_UPDATES upgradable packages (including non-security updates): $AVAILABLE_PACKAGES"
    fi
fi

# Read recent log entries and analyze what happened
if [[ ! -f "$LOG_FILE" ]]; then
    log "WARNING: Log file $LOG_FILE not found. Sending notification anyway."
    LOG_OUTPUT="Log file not found at $LOG_FILE"
    UPDATE_STATUS="unknown"
    UPDATE_SUMMARY="Log file not available"
else
    # Create a snapshot to avoid race conditions with active logging
    TEMP_LOG=$(mktemp)
    trap "rm -f $TEMP_LOG" EXIT
    cp "$LOG_FILE" "$TEMP_LOG" 2>/dev/null || cat "$LOG_FILE" > "$TEMP_LOG"
    
    # Get recent log entries (configurable amount)
    RECENT_LOG=$(tail -n "$MAX_LOG_LINES" "$TEMP_LOG")
    
    # Analyze what happened based on OS type with robust pattern matching
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Debian/Ubuntu - check for actual package installations
        if echo "$RECENT_LOG" | grep -qE "(Packages that will be upgraded|The following packages will be upgraded):"; then
            # Count actual package lines with multiple patterns
            UPGRADED_PACKAGES=$(echo "$RECENT_LOG" | grep -A 50 -E "(Packages that will be upgraded|The following packages will be upgraded):" | grep -E "^  [a-zA-Z0-9][a-zA-Z0-9+.-]*|^[a-zA-Z0-9][a-zA-Z0-9+.-]*" | wc -l)
            if [[ $UPGRADED_PACKAGES -gt 0 ]]; then
                UPDATE_STATUS="updated"
                UPDATE_SUMMARY="$UPGRADED_PACKAGES package(s) updated"
            else
                UPDATE_STATUS="no-updates"
                UPDATE_SUMMARY="No updates available"
            fi
        elif echo "$RECENT_LOG" | grep -qE "(No packages found that can be upgraded|No upgrades available)"; then
            UPDATE_STATUS="no-updates"
            UPDATE_SUMMARY="No updates available"
        elif echo "$RECENT_LOG" | grep -qE "(Unattended-upgrades log started|Starting unattended upgrades)"; then
            # Check if any actual upgrades happened
            if echo "$RECENT_LOG" | grep -qE "(upgraded|installed|configured)"; then
                UPDATE_STATUS="updated"
                UPDATE_SUMMARY="Packages updated"
            else
                UPDATE_STATUS="no-updates"
                UPDATE_SUMMARY="Update check completed, no changes"
            fi
        else
            UPDATE_STATUS="unknown"
            UPDATE_SUMMARY="Update process completed"
        fi
    else
        # RHEL/Fedora - check DNF/YUM logs with improved patterns
        if echo "$RECENT_LOG" | grep -qE "(Upgraded|Updated|Installed):"; then
            # Try multiple methods to extract package count
            UPGRADED_COUNT=$(echo "$RECENT_LOG" | grep -E "(Upgraded|Updated|Installed):" | tail -1 | grep -oE "[0-9]+" | head -1)
            if [[ -z "$UPGRADED_COUNT" ]]; then
                # Fallback: count package lines
                UPGRADED_COUNT=$(echo "$RECENT_LOG" | grep -E "(Upgrading|Installing|Updating)" | wc -l)
            fi
            if [[ -n "$UPGRADED_COUNT" ]] && [[ $UPGRADED_COUNT -gt 0 ]]; then
                UPDATE_STATUS="updated"
                UPDATE_SUMMARY="$UPGRADED_COUNT package(s) updated"
            else
                UPDATE_STATUS="updated"
                UPDATE_SUMMARY="Packages updated"
            fi
        elif echo "$RECENT_LOG" | grep -qE "(Nothing to do|No packages marked for update)"; then
            UPDATE_STATUS="no-updates"
            UPDATE_SUMMARY="No updates available"
        elif echo "$RECENT_LOG" | grep -qE "(Complete!|Transaction complete)"; then
            # Check if any packages were actually processed
            if echo "$RECENT_LOG" | grep -qE "(Installing|Upgrading|Updating).*:" && ! echo "$RECENT_LOG" | grep -qE "(Nothing to do|No packages)"; then
                UPDATE_STATUS="updated"
                UPDATE_SUMMARY="Packages updated"
            else
                UPDATE_STATUS="no-updates"
                UPDATE_SUMMARY="Update check completed, no changes"
            fi
        else
            UPDATE_STATUS="unknown"
            UPDATE_SUMMARY="Update process completed"
        fi
    fi
    
    # Create human-readable summary from logs
    HUMAN_SUMMARY=""
    
    # Check for updates available/applied
    if grep -q "packages upgraded" "$TEMP_LOG" 2>/dev/null; then
        PACKAGE_COUNT=$(grep "packages upgraded" "$TEMP_LOG" | tail -n 1 | awk '{print $1}')
        HUMAN_SUMMARY="✅ Updates Applied: ${PACKAGE_COUNT} packages upgraded"
    elif [[ "$AVAILABLE_UPDATES" -gt 0 ]]; then
        HUMAN_SUMMARY="📦 Updates Available: ${AVAILABLE_UPDATES} non-security packages\n   Packages: ${AVAILABLE_PACKAGES}"
        if [[ "$AVAILABLE_UPDATES" -gt 10 ]]; then
            HUMAN_SUMMARY="${HUMAN_SUMMARY}... and $((AVAILABLE_UPDATES - 10)) more"
        fi
    elif grep -q "No packages found that can be upgraded" "$TEMP_LOG" 2>/dev/null; then
        HUMAN_SUMMARY="✅ System Status: No updates available"
    fi
    
    # Check for held back packages
    if grep -q "kept back" "$TEMP_LOG" 2>/dev/null; then
        HELD_PACKAGES=$(grep "kept back" "$TEMP_LOG" | tail -n 1 | sed 's/.*kept back: //' | sed 's/,/, /g')
        HUMAN_SUMMARY="${HUMAN_SUMMARY}\n⚠️  Packages Held Back: ${HELD_PACKAGES}"
    elif grep -q "packages kept back" "$TEMP_LOG" 2>/dev/null; then
        HELD_COUNT=$(grep "packages kept back" "$TEMP_LOG" | tail -n 1 | awk '{print $1}')
        HUMAN_SUMMARY="${HUMAN_SUMMARY}\n⚠️  Packages Held Back: ${HELD_COUNT} packages require manual review"
    fi
    
    # Check for errors
    if grep -qE "(ERROR|CRITICAL)" "$TEMP_LOG" 2>/dev/null; then
        ERROR_MSG=$(grep -E "(ERROR|CRITICAL)" "$TEMP_LOG" | tail -n 1 | sed 's/^[0-9: -]*[A-Z]* //')
        HUMAN_SUMMARY="${HUMAN_SUMMARY}\n❌ Error: ${ERROR_MSG}"
    fi
    
    # Default if nothing was found
    if [[ -z "$HUMAN_SUMMARY" ]]; then
        HUMAN_SUMMARY="✅ Update check completed successfully"
    fi
    
    # Prepare for JSON (safely escaped)
    LOG_OUTPUT=$(echo -e "$HUMAN_SUMMARY" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read())[1:-1])" 2>/dev/null || {
        # Simple fallback escaping for JSON
        echo -e "$HUMAN_SUMMARY" | awk '{gsub(/\\/,"\\\\",$0); gsub(/"/,"\\\"",$0); gsub(/\t/,"\\t",$0); printf "%s ", $0}' | sed 's/[[:cntrl:]]//g'
    })
    
    log "INFO: Detected OS: $OS_TYPE, Status: $UPDATE_STATUS, Summary: $UPDATE_SUMMARY"
fi

# Set notification title and description based on status
case "$UPDATE_STATUS" in
    "updated")
        NOTIFICATION_TITLE="System Updates Applied on $HOSTNAME"
        NOTIFICATION_DESC="$UPDATE_SUMMARY at **$LAST_RUN**"
        NOTIFICATION_COLOR=5814783  # Green
        ;;
    "no-updates")
        NOTIFICATION_TITLE="System Update Check Complete on $HOSTNAME"
        NOTIFICATION_DESC="$UPDATE_SUMMARY at **$LAST_RUN**"
        NOTIFICATION_COLOR=3447003  # Blue
        ;;
    *)
        NOTIFICATION_TITLE="System Update Process Complete on $HOSTNAME"
        NOTIFICATION_DESC="$UPDATE_SUMMARY at **$LAST_RUN**"
        NOTIFICATION_COLOR=15844367 # Yellow
        ;;
esac

# Track success/failure
NOTIFICATION_SENT=false
ERRORS=""

# Function to send HTTP request with retry
send_webhook() {
    local url="$1" payload="$2" platform="$3"
    
    # Validate webhook URL
    if ! validate_webhook "$url" "$platform"; then
        return 1
    fi
    
    # Skip actual sending in dry run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY_RUN: Would send notification to $platform"
        return 0
    fi
    
    for ((i=1; i<=RETRY_COUNT; i++)); do
        local response
        response=$(curl -s -w "\n%{http_code}" --max-time "$CURL_TIMEOUT" \
            -H "Content-Type: application/json" -X POST -d "$payload" "$url" 2>/dev/null || echo "\n000")
        local http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | head -n-1)
        
        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            log "SUCCESS: Sent notification to $platform (HTTP $http_code)"
            return 0
        else
            log "WARNING: Failed to send to $platform (HTTP $http_code, attempt $i/$RETRY_COUNT)"
            [[ $i -lt $RETRY_COUNT ]] && sleep "$RETRY_DELAY"
        fi
    done
    
    log "ERROR: All retry attempts failed for $platform"
    return 1
}

# Validate configured webhooks
[[ -n "$DISCORD_WEBHOOK" ]] && validate_webhook "$DISCORD_WEBHOOK" "Discord"
[[ -n "$TEAMS_WEBHOOK" ]] && validate_webhook "$TEAMS_WEBHOOK" "Teams"
[[ -n "$SLACK_WEBHOOK" ]] && validate_webhook "$SLACK_WEBHOOK" "Slack"

# Send to Discord if webhook is configured
if [[ -n "$DISCORD_WEBHOOK" ]]; then
    log "INFO: Sending notification to Discord..."
    
    # Build Discord payload with embedded message
    DISCORD_PAYLOAD=$(cat <<EOF
{
  "username": "Linux Updates",
  "embeds": [
    {
      "title": "$NOTIFICATION_TITLE",
      "description": "$NOTIFICATION_DESC\n\n\`\`\`$LOG_OUTPUT\`\`\`",
      "color": $NOTIFICATION_COLOR,
      "timestamp": "$LAST_RUN_UTC",
      "footer": {
        "text": "System Update Notification"
      }
    }
  ]
}
EOF
    )

    # Send notification to Discord
    if send_webhook "$DISCORD_WEBHOOK" "$DISCORD_PAYLOAD" "Discord"; then
        NOTIFICATION_SENT=true
    else
        ERRORS="${ERRORS}Discord: Failed after retries\n"
    fi
fi

# Send to Microsoft Teams if webhook is configured
if [[ -n "$TEAMS_WEBHOOK" ]]; then
    log "INFO: Sending notification to Microsoft Teams..."
    
    # Build Teams payload (Adaptive Card format)
    TEAMS_PAYLOAD=$(cat <<EOF
{
  "@type": "MessageCard",
  "@context": "https://schema.org/extensions",
  "summary": "$NOTIFICATION_TITLE",
  "themeColor": "0078D7",
  "title": "🔄 $(echo "$NOTIFICATION_TITLE" | sed 's/on .*//')",
  "sections": [
    {
      "activityTitle": "Host: **$HOSTNAME**",
      "activitySubtitle": "$NOTIFICATION_DESC",
      "facts": [
        {
          "name": "Status:",
          "value": "$UPDATE_SUMMARY"
        },
        {
          "name": "Log File:",
          "value": "$LOG_FILE"
        }
      ],
      "text": "\`\`\`\\n$LOG_OUTPUT\\n\`\`\`"
    }
  ]
}
EOF
    )

    # Send notification to Teams
    if send_webhook "$TEAMS_WEBHOOK" "$TEAMS_PAYLOAD" "Teams"; then
        NOTIFICATION_SENT=true
    else
        ERRORS="${ERRORS}Teams: Failed after retries\n"
    fi
fi

# Send to Slack if webhook is configured
if [[ -n "$SLACK_WEBHOOK" ]]; then
    log "INFO: Sending notification to Slack..."
    
    # Build Slack payload (Block Kit format)
    SLACK_PAYLOAD=$(cat <<EOF
{
  "text": "$NOTIFICATION_TITLE",
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "🔄 $(echo "$NOTIFICATION_TITLE" | sed 's/on .*//')"
      }
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*Host:*\\n$HOSTNAME"
        },
        {
          "type": "mrkdwn",
          "text": "*Status:*\\n$UPDATE_SUMMARY"
        }
      ]
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Status:*\\n$LOG_OUTPUT"
      }
    }
  ]
}
EOF
    )

    # Send notification to Slack
    if send_webhook "$SLACK_WEBHOOK" "$SLACK_PAYLOAD" "Slack"; then
        NOTIFICATION_SENT=true
    else
        ERRORS="${ERRORS}Slack: Failed after retries\n"
    fi
fi

# Send to Matrix if configured
if [[ "$MATRIX_CONFIGURED" == true ]]; then
    log "INFO: Sending notification to Matrix..."
    
    # Create human-readable summary for Matrix (reuse the same logic)
    MATRIX_SUMMARY=""
    
    # Check for updates available/applied
    if grep -q "packages upgraded" "$TEMP_LOG" 2>/dev/null; then
        PACKAGE_COUNT=$(grep "packages upgraded" "$TEMP_LOG" | tail -n 1 | awk '{print $1}')
        MATRIX_SUMMARY="✅ Updates Applied: ${PACKAGE_COUNT} packages upgraded"
    elif [[ "$AVAILABLE_UPDATES" -gt 0 ]]; then
        MATRIX_SUMMARY="📦 Updates Available: ${AVAILABLE_UPDATES} non-security packages\n   Packages: ${AVAILABLE_PACKAGES}"
        if [[ "$AVAILABLE_UPDATES" -gt 10 ]]; then
            MATRIX_SUMMARY="${MATRIX_SUMMARY}... and $((AVAILABLE_UPDATES - 10)) more"
        fi
    elif grep -q "No packages found that can be upgraded" "$TEMP_LOG" 2>/dev/null; then
        MATRIX_SUMMARY="✅ System Status: No updates available"
    fi
    
    # Check for held back packages
    if grep -q "kept back" "$TEMP_LOG" 2>/dev/null; then
        HELD_PACKAGES=$(grep "kept back" "$TEMP_LOG" | tail -n 1 | sed 's/.*kept back: //' | sed 's/,/, /g')
        MATRIX_SUMMARY="${MATRIX_SUMMARY}\n⚠️  Packages Held Back: ${HELD_PACKAGES}"
    elif grep -q "packages kept back" "$TEMP_LOG" 2>/dev/null; then
        HELD_COUNT=$(grep "packages kept back" "$TEMP_LOG" | tail -n 1 | awk '{print $1}')
        MATRIX_SUMMARY="${MATRIX_SUMMARY}\n⚠️  Packages Held Back: ${HELD_COUNT} packages require manual review"
    fi
    
    # Check for errors
    if grep -qE "(ERROR|CRITICAL)" "$TEMP_LOG" 2>/dev/null; then
        ERROR_MSG=$(grep -E "(ERROR|CRITICAL)" "$TEMP_LOG" | tail -n 1 | sed 's/^[0-9: -]*[A-Z]* //')
        MATRIX_SUMMARY="${MATRIX_SUMMARY}\n❌ Error: ${ERROR_MSG}"
    fi
    
    # Default if nothing was found
    if [[ -z "$MATRIX_SUMMARY" ]]; then
        MATRIX_SUMMARY="✅ Update check completed successfully"
    fi
    
    MATRIX_LOG=$(echo -e "$MATRIX_SUMMARY")
    
    if [[ "$MATRIX_USE_API" == true ]]; then
        # Use Matrix Client-Server API with username/password login
        log "INFO: Using Matrix API (homeserver: ${MATRIX_HOMESERVER})"
        
        # Extract just the localpart if username is in full format (@user:homeserver)
        if [[ "$MATRIX_USERNAME" =~ ^@([^:]+):.*$ ]]; then
            MATRIX_USER_LOCALPART="${BASH_REMATCH[1]}"
        else
            MATRIX_USER_LOCALPART="$MATRIX_USERNAME"
        fi
        
        # Step 1: Login to get access token using temp file to avoid credential exposure
        LOGIN_TEMP=$(mktemp)
        trap "rm -f $LOGIN_TEMP" EXIT
        cat > "$LOGIN_TEMP" <<EOF
{
  "type": "m.login.password",
  "user": "$MATRIX_USER_LOCALPART",
  "password": "$MATRIX_PASSWORD"
}
EOF
        
        LOGIN_RESPONSE=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d @"$LOGIN_TEMP" \
            "${MATRIX_HOMESERVER}/_matrix/client/r0/login")
        
        # Extract access token from login response
        ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        
        if [[ -z "$ACCESS_TOKEN" ]]; then
            log "ERROR: Failed to login to Matrix"
            # Log error without exposing credentials
            ERROR_TYPE=$(echo "$LOGIN_RESPONSE" | grep -o '"errcode":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
            log "Error type: $ERROR_TYPE"
            ERRORS="${ERRORS}Matrix: Login failed\n"
        else
            # Step 2: Send message using the access token
            # Create a simple text message (escape special characters for JSON)
            # Escape backslashes first, then quotes, then newlines
            MESSAGE_BODY=$(cat <<MSGEOF
$NOTIFICATION_TITLE

$UPDATE_SUMMARY at $LAST_RUN

Status:
$MATRIX_LOG
MSGEOF
)
            # Properly escape for JSON
            MESSAGE_BODY_ESCAPED=$(echo "$MESSAGE_BODY" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
            
            # Build Matrix API payload - use printf to avoid shell interpretation
            MATRIX_PAYLOAD="{\"msgtype\":\"m.text\",\"body\":\"$MESSAGE_BODY_ESCAPED\"}"
            
            # URL encode the room ID
            ENCODED_ROOM_ID=$(echo -n "$MATRIX_ROOM_ID" | sed 's/:/%3A/g; s/!/%21/g')
            
            # Generate transaction ID (timestamp + random)
            TXN_ID="update_$(date +%s)_$RANDOM"
            
            # Matrix API endpoint
            MATRIX_URL="${MATRIX_HOMESERVER}/_matrix/client/r0/rooms/${ENCODED_ROOM_ID}/send/m.room.message/${TXN_ID}"
            
            # Send notification to Matrix using API with temp file
            MATRIX_TEMP=$(mktemp)
            trap "rm -f $MATRIX_TEMP" EXIT
            echo "$MATRIX_PAYLOAD" > "$MATRIX_TEMP"
            
            RESPONSE=$(curl -s -w "\n%{http_code}" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -X PUT \
                -d @"$MATRIX_TEMP" \
                "$MATRIX_URL")
            
            HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
            RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

            # Check if the request was successful
            if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
                log "SUCCESS: Sent notification to Matrix (HTTP $HTTP_CODE)"
                NOTIFICATION_SENT=true
            else
                log "ERROR: Failed to send notification to Matrix (HTTP $HTTP_CODE)"
                log "Response: $RESPONSE_BODY"
                ERRORS="${ERRORS}Matrix: HTTP $HTTP_CODE\n"
            fi
        fi
        
    else
        # Use Matrix webhook (legacy/custom integration)
        log "INFO: Using Matrix webhook"
        
        MATRIX_PAYLOAD=$(cat <<EOF
{
  "text": "$NOTIFICATION_TITLE\n\n$UPDATE_SUMMARY at $LAST_RUN\n\nStatus:\n$MATRIX_LOG",
  "format": "plain",
  "displayName": "Linux Updates"
}
EOF
        )
        
        # Send notification to Matrix webhook
        RESPONSE=$(curl -s -w "\n%{http_code}" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "$MATRIX_PAYLOAD" \
            "$MATRIX_WEBHOOK")
        
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

        # Check if the request was successful
        if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
            log "SUCCESS: Sent notification to Matrix (HTTP $HTTP_CODE)"
            NOTIFICATION_SENT=true
        else
            log "ERROR: Failed to send notification to Matrix (HTTP $HTTP_CODE)"
            log "Response: $RESPONSE_BODY"
            ERRORS="${ERRORS}Matrix: HTTP $HTTP_CODE\n"
        fi
    fi
fi

# Summary and exit
if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN: Notification simulation complete"
    exit 0
elif [[ "$NOTIFICATION_SENT" == true ]]; then
    log "SUCCESS: Notification delivery complete"
    exit 0
else
    log "ERROR: All notification attempts failed"
    log "Errors: $ERRORS"
    # In production, you might want to send to a fallback notification method here
    exit 1
fi
