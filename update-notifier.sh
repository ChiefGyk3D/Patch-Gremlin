#!/bin/bash

# Patch Gremlin - Multi-Platform Update Notifier
# Sends system update notifications to Discord and/or Matrix
# Supports both Doppler and local file storage for secrets
# https://github.com/ChiefGyk3D/Patch-Gremlin

# Check if using local secrets file
if [[ -f /etc/update-notifier/secrets.conf ]]; then
    source /etc/update-notifier/secrets.conf
    SECRET_MODE="${SECRET_MODE:-local}"
fi

# Load configuration from file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    source "$SCRIPT_DIR/config.sh"
elif [[ -f /etc/update-notifier/config.sh ]]; then
    source /etc/update-notifier/config.sh
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
# Auto-detect update log file location based on OS
if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    # Debian/Ubuntu
    LOG_FILE="/var/log/unattended-upgrades/unattended-upgrades.log"
elif [[ -f /var/log/dnf.log ]]; then
    # RHEL/Fedora/Amazon Linux  
    LOG_FILE="/var/log/dnf.log"
elif [[ -f /var/log/yum.log ]]; then
    # Older RHEL/CentOS
    LOG_FILE="/var/log/yum.log"
else
    # Fallback
    LOG_FILE="/var/log/unattended-upgrades/unattended-upgrades.log"
fi
HOSTNAME=$(hostname)
LAST_RUN=$(date)

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
        echo "Error: Doppler CLI is not installed. Please install it first."
        echo "Visit: https://docs.doppler.com/docs/install-cli"
        exit 1
    fi
    
    # Retrieve webhook URLs and Matrix credentials from Doppler
    DISCORD_WEBHOOK=$(doppler secrets get "$DOPPLER_DISCORD_SECRET" --plain 2>/dev/null)
    TEAMS_WEBHOOK=$(doppler secrets get "$DOPPLER_TEAMS_SECRET" --plain 2>/dev/null)
    SLACK_WEBHOOK=$(doppler secrets get "$DOPPLER_SLACK_SECRET" --plain 2>/dev/null)

    # Matrix can use either webhooks OR homeserver + username + password + room ID
    MATRIX_WEBHOOK=$(doppler secrets get "$DOPPLER_MATRIX_SECRET" --plain 2>/dev/null)
    MATRIX_HOMESERVER=$(doppler secrets get "$DOPPLER_MATRIX_HOMESERVER_SECRET" --plain 2>/dev/null)
    MATRIX_USERNAME=$(doppler secrets get "$DOPPLER_MATRIX_USERNAME_SECRET" --plain 2>/dev/null)
    MATRIX_PASSWORD=$(doppler secrets get "$DOPPLER_MATRIX_PASSWORD_SECRET" --plain 2>/dev/null)
    MATRIX_ROOM_ID=$(doppler secrets get "$DOPPLER_MATRIX_ROOM_ID_SECRET" --plain 2>/dev/null)
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
    echo "Error: No notification methods configured."
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

# Read recent log entries
if [[ ! -f "$LOG_FILE" ]]; then
    echo "Warning: Log file $LOG_FILE not found. Sending notification anyway."
    LOG_OUTPUT="Log file not found at $LOG_FILE"
else
    # Properly escape for JSON: escape quotes, backslashes, and newlines
    LOG_OUTPUT=$(tail -n 15 "$LOG_FILE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
fi

# Track success/failure
NOTIFICATION_SENT=false
ERRORS=""

# Send to Discord if webhook is configured
if [[ -n "$DISCORD_WEBHOOK" ]]; then
    echo "Sending notification to Discord..."
    
    # Build Discord payload with embedded message
    DISCORD_PAYLOAD=$(cat <<EOF
{
  "username": "Linux Updates",
  "embeds": [
    {
      "title": "System Update Completed on $HOSTNAME",
      "description": "Unattended-upgrades ran at **$LAST_RUN**.\n\n\`\`\`$LOG_OUTPUT\`\`\`",
      "color": 5814783,
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
      "footer": {
        "text": "System Update Notification"
      }
    }
  ]
}
EOF
    )

    # Send notification to Discord
    RESPONSE=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST -d "$DISCORD_PAYLOAD" "$DISCORD_WEBHOOK")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

    # Check if the request was successful
    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        echo "✓ Successfully sent notification to Discord (HTTP $HTTP_CODE)"
        NOTIFICATION_SENT=true
    else
        echo "✗ Failed to send notification to Discord (HTTP $HTTP_CODE)"
        echo "  Response: $RESPONSE_BODY"
        ERRORS="${ERRORS}Discord: HTTP $HTTP_CODE\n"
    fi
fi

# Send to Microsoft Teams if webhook is configured
if [[ -n "$TEAMS_WEBHOOK" ]]; then
    echo "Sending notification to Microsoft Teams..."
    
    # Build Teams payload (Adaptive Card format)
    TEAMS_PAYLOAD=$(cat <<EOF
{
  "@type": "MessageCard",
  "@context": "https://schema.org/extensions",
  "summary": "System Update Completed on $HOSTNAME",
  "themeColor": "0078D7",
  "title": "🔄 System Update Completed",
  "sections": [
    {
      "activityTitle": "Host: **$HOSTNAME**",
      "activitySubtitle": "Update completed at $LAST_RUN",
      "facts": [
        {
          "name": "Status:",
          "value": "Security updates applied"
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
    RESPONSE=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST -d "$TEAMS_PAYLOAD" "$TEAMS_WEBHOOK")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        echo "✓ Successfully sent notification to Microsoft Teams (HTTP $HTTP_CODE)"
        NOTIFICATION_SENT=true
    else
        echo "✗ Failed to send notification to Microsoft Teams (HTTP $HTTP_CODE)"
        echo "  Response: $RESPONSE_BODY"
        ERRORS="${ERRORS}Teams: HTTP $HTTP_CODE\n"
    fi
fi

# Send to Slack if webhook is configured
if [[ -n "$SLACK_WEBHOOK" ]]; then
    echo "Sending notification to Slack..."
    
    # Build Slack payload (Block Kit format)
    SLACK_PAYLOAD=$(cat <<EOF
{
  "text": "System Update Completed on $HOSTNAME",
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "🔄 System Update Completed"
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
          "text": "*Time:*\\n$LAST_RUN"
        }
      ]
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Recent Log:*\\n\`\`\`$LOG_OUTPUT\`\`\`"
      }
    }
  ]
}
EOF
    )

    # Send notification to Slack
    RESPONSE=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST -d "$SLACK_PAYLOAD" "$SLACK_WEBHOOK")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        echo "✓ Successfully sent notification to Slack (HTTP $HTTP_CODE)"
        NOTIFICATION_SENT=true
    else
        echo "✗ Failed to send notification to Slack (HTTP $HTTP_CODE)"
        echo "  Response: $RESPONSE_BODY"
        ERRORS="${ERRORS}Slack: HTTP $HTTP_CODE\n"
    fi
fi

# Send to Matrix if configured
if [[ "$MATRIX_CONFIGURED" == true ]]; then
    echo "Sending notification to Matrix..."
    
    # Format log output for Matrix (plain text with newlines)
    MATRIX_LOG=$(tail -n 15 "$LOG_FILE" 2>/dev/null || echo "Log file not found")
    
    if [[ "$MATRIX_USE_API" == true ]]; then
        # Use Matrix Client-Server API with username/password login
        echo "Using Matrix API (homeserver: ${MATRIX_HOMESERVER})"
        
        # Extract just the localpart if username is in full format (@user:homeserver)
        if [[ "$MATRIX_USERNAME" =~ ^@([^:]+): ]]; then
            MATRIX_USER_LOCALPART="${BASH_REMATCH[1]}"
        else
            MATRIX_USER_LOCALPART="$MATRIX_USERNAME"
        fi
        
        # Step 1: Login to get access token
        LOGIN_PAYLOAD=$(cat <<EOF
{
  "type": "m.login.password",
  "user": "$MATRIX_USER_LOCALPART",
  "password": "$MATRIX_PASSWORD"
}
EOF
        )
        
        LOGIN_RESPONSE=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$LOGIN_PAYLOAD" \
            "${MATRIX_HOMESERVER}/_matrix/client/r0/login")
        
        # Extract access token from login response
        ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        
        if [[ -z "$ACCESS_TOKEN" ]]; then
            echo "✗ Failed to login to Matrix"
            echo "  Response: $LOGIN_RESPONSE"
            ERRORS="${ERRORS}Matrix: Login failed\n"
        else
            # Step 2: Send message using the access token
            # Create a simple text message (escape special characters for JSON)
            # Escape backslashes first, then quotes, then newlines
            MESSAGE_BODY=$(cat <<MSGEOF
System Update Completed on $HOSTNAME

Unattended-upgrades ran at $LAST_RUN

Recent log:
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
            
            # Send notification to Matrix using API
            RESPONSE=$(curl -s -w "\n%{http_code}" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -X PUT \
                -d "$MATRIX_PAYLOAD" \
                "$MATRIX_URL")
            
            HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
            RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

            # Check if the request was successful
            if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
                echo "✓ Successfully sent notification to Matrix (HTTP $HTTP_CODE)"
                NOTIFICATION_SENT=true
            else
                echo "✗ Failed to send notification to Matrix (HTTP $HTTP_CODE)"
                echo "  Response: $RESPONSE_BODY"
                ERRORS="${ERRORS}Matrix: HTTP $HTTP_CODE\n"
            fi
        fi
        
    else
        # Use Matrix webhook (legacy/custom integration)
        echo "Using Matrix webhook"
        
        MATRIX_PAYLOAD=$(cat <<EOF
{
  "text": "System Update Completed on $HOSTNAME\n\nUnattended-upgrades ran at $LAST_RUN\n\nRecent log:\n$MATRIX_LOG",
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
            echo "✓ Successfully sent notification to Matrix (HTTP $HTTP_CODE)"
            NOTIFICATION_SENT=true
        else
            echo "✗ Failed to send notification to Matrix (HTTP $HTTP_CODE)"
            echo "  Response: $RESPONSE_BODY"
            ERRORS="${ERRORS}Matrix: HTTP $HTTP_CODE\n"
        fi
    fi
fi

# Exit with appropriate status
if [[ "$NOTIFICATION_SENT" == true ]]; then
    echo "Notification delivery complete"
    exit 0
else
    echo "Error: All notification attempts failed"
    echo -e "$ERRORS"
    exit 1
fi
