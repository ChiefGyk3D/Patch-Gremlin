# Debian Update Notifier

Automated system update notifications for Debian with Discord and Matrix support. Integrates with `unattended-upgrades` to send notifications when security updates are installed.

## Features

- 🔔 **Multi-Platform**: Send notifications to Discord and/or Matrix
- 🔒 **Secure**: Uses Doppler CLI for credential management
- 🎨 **Configurable**: Customize Doppler secret names to avoid conflicts
- ⚙️ **Automated**: Integrates with unattended-upgrades and systemd
- 📊 **Informative**: Rich notifications with hostname, timestamp, and logs
- 🔐 **Simple Auth**: Matrix uses username/password (no token generation needed)

## Quick Start

### 1. Install Dependencies

```bash
# Install Doppler CLI
curl -sLf https://cli.doppler.com/install.sh | sh

# Authenticate (both user and root need separate authentication)
doppler login
sudo doppler login
```

### 2. Configure Doppler

```bash
# Setup Doppler project
sudo doppler setup --project your-project --config your-config

# Add secrets (example with custom names)
doppler secrets set SYSTEM_UPDATE_DISCORD="https://discord.com/api/webhooks/..."
doppler secrets set MATRIX_HOMESERVER="https://matrix.org"
doppler secrets set MATRIX_USERNAME="youruser"  # Just username, not @user:server
doppler secrets set MATRIX_PASSWORD="your-password"
doppler secrets set SYSTEM_UPDATE_MATRIX_ROOM="!roomid:matrix.org"
```

### 3. Configure Secret Names

```bash
# Copy example config and customize
cp config.example.sh config.sh
nano config.sh
```

Edit to match your Doppler secret names:
```bash
export DOPPLER_DISCORD_SECRET="SYSTEM_UPDATE_DISCORD"
export DOPPLER_MATRIX_HOMESERVER_SECRET="MATRIX_HOMESERVER"
export DOPPLER_MATRIX_USERNAME_SECRET="MATRIX_USERNAME"
export DOPPLER_MATRIX_PASSWORD_SECRET="MATRIX_PASSWORD"
export DOPPLER_MATRIX_ROOM_ID_SECRET="SYSTEM_UPDATE_MATRIX_ROOM"
```

### 4. Install

```bash
sudo ./setup-unattended-upgrades.sh
```

The setup script will:
- Install and configure unattended-upgrades for security updates
- Copy config.sh to `/etc/update-notifier/`
- Install notification script to `/usr/local/bin/`
- Create systemd service and timer
- Setup APT post-upgrade hook

### 5. Test

```bash
# Verify installation
./test-setup.sh

# Test notification
sudo /usr/local/bin/update-notifier.sh
```

## How It Works

1. **unattended-upgrades** automatically installs security updates
2. **APT hook** triggers notification script after upgrades complete
3. **systemd timer** provides backup daily notifications
4. **Notification script**:
   - Loads config from `/etc/update-notifier/config.sh`
   - Retrieves credentials from Doppler using custom secret names
   - Sends formatted notifications to configured platforms

## Configuration

### Doppler Secret Names

The script supports custom Doppler secret names via `config.sh`. This allows you to:
- Avoid conflicts with other applications
- Use consistent naming across your infrastructure
- Namespace secrets by hostname or environment

**Default names** (if no config.sh):
- `UPDATE_NOTIFIER_DISCORD_WEBHOOK`
- `UPDATE_NOTIFIER_MATRIX_HOMESERVER`
- `UPDATE_NOTIFIER_MATRIX_USERNAME`
- `UPDATE_NOTIFIER_MATRIX_PASSWORD`
- `UPDATE_NOTIFIER_MATRIX_ROOM_ID`

**Custom names** (via config.sh):
```bash
export DOPPLER_DISCORD_SECRET="SYSTEM_UPDATE_DISCORD"
export DOPPLER_MATRIX_HOMESERVER_SECRET="MATRIX_HOMESERVER"
# ... etc
```

### Matrix Username Format

In Doppler, store just the **localpart** of your Matrix username (without `@` or `:homeserver`):
- ✅ Correct: `username`
- ❌ Wrong: `@username:matrix.org`

The script will automatically extract the localpart if you accidentally include the full format.

## Files Installed

```
/usr/local/bin/update-notifier.sh          # Main notification script
/etc/update-notifier/config.sh             # Custom secret name configuration
/etc/systemd/system/update-notifier.service # Systemd service
/etc/systemd/system/update-notifier.timer   # Daily timer
/etc/apt/apt.conf.d/99discord-notification  # APT hook
/etc/apt/apt.conf.d/50unattended-upgrades   # Security update config
```

## Troubleshooting

### Config not loading

```bash
# Ensure config exists in system location
sudo cp ~/src/scripts/config.sh /etc/update-notifier/config.sh
sudo chmod 644 /etc/update-notifier/config.sh
```

### Doppler authentication lost after reboot

Doppler stores auth in `/root/.doppler/` which persists across reboots. If you see auth errors:
```bash
sudo doppler login
sudo doppler setup --project your-project --config your-config
```

### Hostname resolution error after changing hostname

Update `/etc/hosts`:
```bash
sudo nano /etc/hosts
# Change old hostname to new hostname on the 127.0.1.1 line
```

### Matrix login fails

Check your username format in Doppler:
```bash
doppler secrets get MATRIX_USERNAME --plain
# Should show just "username", not "@username:server"
```

## Uninstallation

```bash
sudo ./uninstall.sh
```

## Documentation

- **[QUICK_REFERENCE.md](QUICK_REFERENCE.md)** - Command cheat sheet
- **[MATRIX_SETUP.md](MATRIX_SETUP.md)** - Matrix-specific setup
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Detailed troubleshooting

## Requirements

- Debian 12 (Bookworm) or 13 (Trixie)
- Root/sudo access
- Doppler CLI
- Discord webhook URL and/or Matrix account

## License

MIT

## Contributing

Issues and pull requests welcome!
