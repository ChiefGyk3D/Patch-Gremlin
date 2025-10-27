# Matrix Setup Guide

This guide covers setting up Matrix notifications for Patch Gremlin.

## Prerequisites

- Matrix account on any homeserver
- Matrix room where you want to receive notifications
- Room ID for that room

## Quick Setup

### 1. Get Your Matrix Credentials

You need:
- **Homeserver URL**: e.g., `https://matrix.org` or `https://matrix.chiefgyk3d.com`
- **Username**: Your Matrix username (just the localpart, e.g., `username`)
- **Password**: Your Matrix account password
- **Room ID**: The room where notifications will be sent (e.g., `!abc123:matrix.org`)

### 2. Find Your Room ID

**Method 1: Element Web/Desktop**
1. Open the room in Element
2. Click room name → Settings → Advanced
3. Copy the "Internal room ID" (starts with `!`)

**Method 2: Element Mobile**
1. Open the room
2. Tap room name → About
3. Room ID is shown at the bottom

### 3. Add Secrets to Doppler

```bash
# Set Matrix credentials
doppler secrets set MATRIX_HOMESERVER="https://matrix.org"
doppler secrets set MATRIX_USERNAME="username"  # Just username, no @
doppler secrets set MATRIX_PASSWORD="your-password"
doppler secrets set SYSTEM_UPDATE_MATRIX_ROOM="!roomid:matrix.org"
```

**Important**: Use just the username localpart (e.g., `username`), not the full Matrix ID (not `@username:matrix.org`).

### 4. Configure Secret Names

Edit `config.sh`:
```bash
export DOPPLER_MATRIX_HOMESERVER_SECRET="MATRIX_HOMESERVER"
export DOPPLER_MATRIX_USERNAME_SECRET="MATRIX_USERNAME"
export DOPPLER_MATRIX_PASSWORD_SECRET="MATRIX_PASSWORD"
export DOPPLER_MATRIX_ROOM_ID_SECRET="SYSTEM_UPDATE_MATRIX_ROOM"
```

### 5. Install and Test

```bash
# Install
sudo ./setup-unattended-upgrades.sh

# Test
sudo /usr/local/bin/update-notifier.sh
```

## How It Works

The notification script:
1. Reads Matrix credentials from Doppler
2. Sends a login request to your homeserver
3. Receives a temporary access token
4. Uses that token to send a message to your room
5. The access token is discarded (not stored)

This is more secure than storing long-lived access tokens.

## Troubleshooting

### Login Failed - Invalid Username or Password

**Check username format**:
```bash
sudo doppler secrets get MATRIX_USERNAME --plain
# Should show: username
# NOT: @username:matrix.org
```

If it shows the full Matrix ID, update it:
```bash
doppler secrets set MATRIX_USERNAME="username"
```

**Verify password**:
```bash
# Make sure password is correct
sudo doppler secrets get MATRIX_PASSWORD --plain
```

### Failed to Send Message - M_FORBIDDEN

Your user doesn't have permission to send messages in that room.

**Solution**: Ensure your Matrix user has joined the room and has permission to send messages.

### Wrong Homeserver

**Check homeserver URL**:
```bash
sudo doppler secrets get MATRIX_HOMESERVER --plain
# Should be: https://matrix.org (or your homeserver)
# NOT: matrix.org (missing https://)
```

### Invalid Room ID

**Check room ID format**:
```bash
sudo doppler secrets get SYSTEM_UPDATE_MATRIX_ROOM --plain
# Should start with ! and include :homeserver
# Example: !abc123def:matrix.org
```

## Security Notes

- Your Matrix password is stored in Doppler (encrypted at rest)
- Access tokens are temporary and not stored
- Communications with Matrix homeserver use HTTPS
- No persistent access tokens means reduced risk if the system is compromised

## Using a Different Homeserver

To use your own Matrix homeserver:

```bash
# Set your homeserver URL
doppler secrets set MATRIX_HOMESERVER="https://matrix.your-domain.com"

# Your username should match your homeserver
doppler secrets set MATRIX_USERNAME="youruser"

# Room ID will include your homeserver domain
doppler secrets set SYSTEM_UPDATE_MATRIX_ROOM="!roomid:your-domain.com"
```

## Creating a Dedicated Notification Room

Recommended: Create a dedicated room for system notifications.

1. Create a new room in Element
2. Set it to "Private" or "Public" as preferred
3. Get the room ID from room settings
4. Add the room ID to Doppler

## Bot User (Optional)

For better organization, create a dedicated bot account:

1. Register a new Matrix account (e.g., `update-bot`)
2. Invite the bot to your notification room
3. Use the bot's credentials in Doppler

This separates notification messages from your personal account.
