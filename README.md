# Patch Gremlin
<div align="center">
  <img src="media/patch_gremlin_banner.png" alt="Patch Gremlin Banner" width="400"/>
</div>

Automated system update notifications for Debian and RHEL-based systems with Discord, Microsoft Teams, Slack, and Matrix support. Integrates with `unattended-upgrades` (Debian/Ubuntu) or `dnf-automatic` (RHEL/Fedora/Amazon Linux) to send notifications when security updates are installed.

## Features

- 🔔 **Multi-Platform**: Send notifications to Discord, Microsoft Teams, Slack, and/or Matrix (any combination!)
- 🔒 **Flexible Secrets**: Use Doppler for centralized management OR local file storage
- 🎨 **Configurable**: Customize secret names and update schedules
- ⚙️ **Automated**: Integrates with unattended-upgrades and systemd
- 🧠 **Intelligent**: Analyzes logs to distinguish between "5 packages updated" vs "no updates available"
- 📊 **Informative**: Rich notifications with hostname, timezone-aware timestamps, and logs
- 🌍 **Timezone-Aware**: Detects and configures system timezone during setup
- 🔐 **Simple Auth**: Matrix uses username/password (no token generation needed)
- 🖥️ **Multi-OS**: Supports Debian/Ubuntu and RHEL/Rocky/AlmaLinux/Amazon Linux/Fedora
- 🔇 **Clean Logs**: Configurable verbosity (quiet by default)

## Quick Start

### Installation Methods

Choose your preferred method for storing notification secrets:

#### Option 1: Local File Storage (Simpler)

Secrets stored in `/etc/update-notifier/secrets.conf` - no external dependencies.

```bash
# 1. Clone and enter directory
git clone https://github.com/ChiefGyk3D/Patch-Gremlin.git
cd Patch-Gremlin

# 2. Run setup (it will prompt for secret storage choice)
sudo ./setup-unattended-upgrades.sh

# 3. Follow prompts:
#    - Choose update type (security only / all updates)
#    - Choose schedule (daily / weekly)
#    - Choose timezone
#    - Choose verbose logging (default: quiet)
#    - Choose LOCAL file storage
#    - Enter webhook URLs for your platforms

# Done! Test the notification:
sudo /usr/local/bin/update-notifier.sh
```

#### Option 2: Doppler (Centralized Secret Management)

Best for managing multiple servers or sharing secrets across teams.

```bash
# 1. Install Doppler CLI
curl -sLf https://cli.doppler.com/install.sh | sh

# 2. Authenticate (both user and root)
doppler login
sudo doppler login

# 3. Setup Doppler project
sudo doppler setup --project your-project --config your-config

# 4. Add secrets (choose platforms you want)
doppler secrets set UPDATE_NOTIFIER_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
doppler secrets set UPDATE_NOTIFIER_MATRIX_HOMESERVER="https://matrix.org"
doppler secrets set UPDATE_NOTIFIER_MATRIX_USERNAME="username"
doppler secrets set UPDATE_NOTIFIER_MATRIX_PASSWORD="your-password"
doppler secrets set UPDATE_NOTIFIER_MATRIX_ROOM_ID="!room:matrix.org"

# 5. Clone and run setup
git clone https://github.com/ChiefGyk3D/Patch-Gremlin.git
cd Patch-Gremlin
sudo ./setup-unattended-upgrades.sh

# 6. Follow prompts and choose DOPPLER mode
#    You'll need to provide your Doppler service token when prompted

# Done! Test the notification:
sudo /usr/local/bin/update-notifier.sh
```

### Creating a Doppler Service Token

When using Doppler mode, the setup will prompt for a service token:

```bash
# Create a service token (no expiration)
doppler configs tokens create patch-gremlin-token --max-age 0

# Copy the token (starts with dp.st.) and paste when prompted
```

The service token allows the notification script to access your secrets without requiring doppler login on the system.

## Configuration

### Interactive Setup

The setup script (`setup-unattended-upgrades.sh`) will interactively ask you about:

1. **Update Type**
   - Security updates only (recommended)
   - All available updates

2. **Update Schedule**
   - Daily (recommended for security)
   - Weekly (choose day of week)
   - Custom time (default: 02:00)

3. **Timezone**
   - Keep current or select from common timezones

4. **Verbose Logging**
   - Quiet (recommended) - only important messages
   - Verbose - detailed DEBUG output

5. **Secret Storage**
   - LOCAL file - simpler, secrets in `/etc/update-notifier/secrets.conf`
   - DOPPLER - centralized, requires Doppler CLI and service token

6. **Notification Platforms**
   - Discord webhook URL
   - Microsoft Teams webhook URL
   - Slack webhook URL
   - Matrix (webhook OR homeserver + username/password)
   - **At least one required**

### Environment Variable Presets

Skip interactive prompts by setting environment variables before running setup:

```bash
export UPDATE_TYPE="security"              # or "all"
export UPDATE_SCHEDULE="daily"             # or "weekly"
export UPDATE_DAY="Sat"                    # if weekly: Sun, Mon, Tue, Wed, Thu, Fri, Sat
export UPDATE_TIME="02:00"                 # 24-hour format
export SYSTEM_TIMEZONE="US/Eastern"        # or leave unset for current
export VERBOSE_LOGGING="false"             # or "true" for debug
export SECRET_MODE="local"                 # or "doppler"
export DOPPLER_TOKEN="dp.st.xxx"           # if using Doppler mode

# Run setup with presets
sudo -E ./setup-unattended-upgrades.sh
```

### Customizing Doppler Secret Names

If you need different secret names (to avoid conflicts with other programs), create `config.sh`:

```bash
cp config.example.sh config.sh
nano config.sh
```

Edit to match your Doppler secret names:
```bash
# Customize these to match YOUR Doppler secret names
export DOPPLER_DISCORD_SECRET="MY_DISCORD_WEBHOOK"
export DOPPLER_TEAMS_SECRET="MY_TEAMS_WEBHOOK"
export DOPPLER_SLACK_SECRET="MY_SLACK_WEBHOOK"
export DOPPLER_MATRIX_HOMESERVER_SECRET="MY_MATRIX_SERVER"
export DOPPLER_MATRIX_USERNAME_SECRET="MY_MATRIX_USER"
export DOPPLER_MATRIX_PASSWORD_SECRET="MY_MATRIX_PASS"
export DOPPLER_MATRIX_ROOM_ID_SECRET="MY_MATRIX_ROOM"
```

Then run setup with your config:
```bash
source config.sh
sudo -E ./setup-unattended-upgrades.sh
```

### Local Secrets File Format

If using local file storage, secrets are stored in `/etc/update-notifier/secrets.conf`:

```bash
SECRET_MODE="local"

# Discord
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# Microsoft Teams
TEAMS_WEBHOOK="https://outlook.office.com/webhook/..."

# Slack
SLACK_WEBHOOK="https://hooks.slack.com/services/..."

# Matrix - Webhook (if available)
MATRIX_WEBHOOK="https://matrix.example.org/_matrix/webhook/..."

# Matrix - API (recommended)
MATRIX_HOMESERVER="https://matrix.org"
MATRIX_USERNAME="username"
MATRIX_PASSWORD="your-password"
MATRIX_ROOM_ID="!room:matrix.org"
```

**Security**: This file is automatically created with `chmod 600` (owner read/write only).

## Getting Webhook URLs

### Discord
1. Go to Server Settings → Integrations → Webhooks
2. Click "New Webhook" or edit existing
3. Copy webhook URL
4. Format: `https://discord.com/api/webhooks/{id}/{token}`

### Microsoft Teams
1. Go to channel → More options (⋯) → Connectors
2. Search for "Incoming Webhook" → Configure
3. Give it a name, optionally upload image
4. Copy webhook URL
5. Format: `https://outlook.office.com/webhook/...`

### Slack
1. Go to https://api.slack.com/apps
2. Create New App → From scratch
3. Add "Incoming Webhooks" feature
4. Activate and add to workspace
5. Copy webhook URL
6. Format: `https://hooks.slack.com/services/...`

### Matrix

**Getting Your Room ID:**

*Element Web/Desktop:*
1. Open the room → Click room name → Settings → Advanced
2. Copy "Internal room ID" (starts with `!`)

*Element Mobile:*
1. Open room → Tap room name → About
2. Room ID is at the bottom

**Username Format:**
- ✅ Correct: `username` (just the localpart)
- ❌ Wrong: `@username:matrix.org` (full format)

The script will automatically extract the localpart if needed.

## Testing & Diagnostics

### Quick Commands

```bash
# Test notification (dry run - no actual sending)
sudo PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh

# Send real test notification
sudo /usr/local/bin/update-notifier.sh

# Run comprehensive diagnostics
sudo ./diagnose-config.sh

# Quick health check (for monitoring)
sudo ./health-check.sh

# Full deployment test
sudo ./test-deployment.sh

# Toggle verbose logging
sudo ./configure-verbosity.sh

# Check service status
sudo systemctl status update-notifier.timer
sudo systemctl list-timers update-notifier*

# View logs
sudo journalctl -t patch-gremlin --since "1 day ago"
sudo journalctl -f -t patch-gremlin
```

### Monitoring Integration

#### Health Check (Exit Codes)

```bash
sudo ./health-check.sh
# 0 = Healthy
# 1 = Warning (non-critical)
# 2 = Critical (service broken)
```

Perfect for Nagios, Zabbix, Icinga, etc.

#### Diagnostics (Human-Readable)

```bash
sudo ./diagnose-config.sh
```

Shows:
- Secret storage mode (LOCAL vs DOPPLER)
- Configured webhooks
- Service status
- Timer schedule
- Live notification test
- Troubleshooting tips

## Files & Structure

### Installed Files

```
/usr/local/bin/
├── update-notifier.sh                  # Main notification script

/etc/update-notifier/
├── secrets.conf                        # Local secrets (if using local mode)
└── config.sh                           # Doppler config (if using Doppler mode)

/etc/systemd/system/
├── update-notifier.service             # Notification service
├── update-notifier.timer               # Scheduled timer
└── apt-daily-upgrade.timer.d/          # (Debian) Schedule override
    └── schedule.conf

/etc/apt/apt.conf.d/                    # (Debian only)
├── 20auto-upgrades                     # APT periodic config
├── 50unattended-upgrades              # Unattended-upgrades config
└── 99patch-gremlin-notification       # Post-upgrade hook

/etc/dnf/automatic.conf                 # (RHEL only) DNF automatic config
/etc/systemd/system/dnf-automatic.service.d/  # (RHEL only)
└── patch-gremlin.conf                  # Post-upgrade hook

/usr/local/bin/patch-gremlin-dnf-hook.sh      # (RHEL only) DNF hook script
```

### Repository Scripts

```bash
setup-unattended-upgrades.sh    # Interactive installer
update-notifier.sh              # Notification script (copied to /usr/local/bin)
uninstall.sh                    # Complete removal
config.example.sh               # Template for Doppler custom secret names

# User tools
diagnose-config.sh              # Detailed diagnostics + troubleshooting
health-check.sh                 # Simple monitoring (exit codes)
configure-verbosity.sh          # Toggle debug logging on/off
test-deployment.sh              # Comprehensive testing

# Monitoring examples
monitoring/
├── nagios-check.sh             # Nagios/Icinga integration
└── prometheus-exporter.sh      # Prometheus metrics
```

## Advanced Configuration

### Environment Variables

Customize script behavior:

```bash
# Testing
PATCH_GREMLIN_DRY_RUN=true              # Test mode (no actual sending)

# Performance tuning
PATCH_GREMLIN_MAX_LOG_LINES=100         # Log lines (default: 50)
PATCH_GREMLIN_RETRY_COUNT=5             # HTTP retries (default: 3)
PATCH_GREMLIN_RETRY_DELAY=5             # Retry delay seconds (default: 2)
PATCH_GREMLIN_CURL_TIMEOUT=60           # HTTP timeout seconds (default: 30)
```

### Adjusting Verbosity

Change log verbosity after installation:

```bash
# Interactive toggle
sudo ./configure-verbosity.sh

# Shows current setting, lets you enable/disable verbose DEBUG output
```

**Quiet mode (default):**
- Shows package updates installed
- Shows errors if they occur
- Clean, readable logs

**Verbose mode:**
- Shows detailed DEBUG from unattended-upgrades
- Package checking details
- Origin pattern matching
- Useful for troubleshooting

### Upgrading Existing Installation

If Patch Gremlin is already installed, the setup script will detect it and offer options:

```
Options:
  1) Reinstall/Reconfigure (preserves nothing)
  2) Update scripts only (keeps configuration)
  3) Cancel installation
```

Choose option 2 to update the scripts while keeping your current configuration.

## Troubleshooting

### Quick Diagnostics

```bash
# Run comprehensive diagnostics
sudo ./diagnose-config.sh
```

This will check:
- Secret storage configuration
- Systemd service setup
- Timer status and schedule
- Network connectivity
- Live notification test

### Common Issues

#### 1. LOCAL mode but no notifications sent

```bash
# Check secrets file exists and has content
sudo cat /etc/update-notifier/secrets.conf

# Edit and add webhook URLs
sudo nano /etc/update-notifier/secrets.conf

# Test notification
sudo /usr/local/bin/update-notifier.sh
```

#### 2. DOPPLER mode authentication fails

```bash
# Re-authenticate
sudo doppler login
sudo doppler setup --project your-project --config your-config

# Verify secrets exist
doppler secrets --only-names

# Check service has token
systemctl show update-notifier.service | grep DOPPLER_TOKEN
```

#### 3. Timer not running

```bash
# Check timer status
sudo systemctl status update-notifier.timer

# Enable and start if needed
sudo systemctl enable --now update-notifier.timer

# View schedule
sudo systemctl list-timers update-notifier*
```

#### 4. Script runs but notifications fail

```bash
# Check recent logs
sudo journalctl -t patch-gremlin --since "1 hour ago"

# Test with dry run
sudo PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh

# Check webhook URLs are correct
# LOCAL mode:
sudo cat /etc/update-notifier/secrets.conf

# DOPPLER mode:
doppler secrets get UPDATE_NOTIFIER_DISCORD_WEBHOOK --plain
```

#### 5. Too much DEBUG output in logs

```bash
# Disable verbose logging
sudo ./configure-verbosity.sh
# Choose option 1 (Disable)
```

#### 6. Matrix login fails

Check username format - should be just the localpart:
```bash
# LOCAL mode:
grep MATRIX_USERNAME /etc/update-notifier/secrets.conf
# Should show: MATRIX_USERNAME="username"
# NOT: MATRIX_USERNAME="@username:matrix.org"

# DOPPLER mode:
doppler secrets get UPDATE_NOTIFIER_MATRIX_USERNAME --plain
# Should show just: username
```

### Getting Help

1. Run diagnostics: `sudo ./diagnose-config.sh`
2. Check logs: `sudo journalctl -t patch-gremlin --since "1 day ago"`
3. See [GitHub Issues](https://github.com/ChiefGyk3D/Patch-Gremlin/issues)
4. Join [Discord](https://discord.chiefgyk3d.com) or [Matrix](https://matrix-invite.chiefgyk3d.com)

## Uninstallation

```bash
sudo ./uninstall.sh
```

This will remove:
- Notification script from `/usr/local/bin/`
- Systemd service and timer
- Configuration files
- Post-upgrade hooks (APT or DNF)
- Local secrets file (if present)

**Note**: Doppler secrets are NOT removed (they may be used by other systems).

## Requirements

- **OS**: Debian 12+, Ubuntu 20.04+, RHEL 8+, Rocky 8+, AlmaLinux 8+, Amazon Linux 2023, Fedora 35+
- **Access**: Root/sudo privileges
- **Secrets**: At least one notification platform configured
- **Optional**: Doppler CLI (only if using Doppler mode)

## Supported Operating Systems

**Debian-based:**
- Debian 12 (Bookworm), 13 (Trixie)
- Ubuntu 20.04 LTS, 22.04 LTS, 24.04 LTS
- Raspberry Pi OS
- Other Debian derivatives

**RHEL-based:**
- Red Hat Enterprise Linux 8, 9
- Rocky Linux 8, 9
- AlmaLinux 8, 9
- Amazon Linux 2023
- Fedora 35+

## How It Works

### Update Process

**Debian/Ubuntu:**
1. `unattended-upgrades` runs automatically (via systemd timer or apt-daily)
2. Security updates are downloaded and installed
3. APT post-invoke hook triggers `update-notifier.sh`
4. Script analyzes logs and sends notifications

**RHEL/Fedora/Amazon Linux:**
1. `dnf-automatic` runs automatically (via systemd timer)
2. Security updates are downloaded and installed
3. DNF systemd hook triggers `update-notifier.sh`
4. Script analyzes logs and sends notifications

### Notification Script Logic

1. **Load Configuration**
   - Check if LOCAL mode: read `/etc/update-notifier/secrets.conf`
   - Check if DOPPLER mode: use environment variables from systemd service
   - Fall back to Doppler CLI if needed

2. **Analyze Logs**
   - Parse system logs (syslog or journald)
   - Detect actual package updates vs no updates
   - Extract package names and counts
   - Determine notification color/priority

3. **Send Notifications**
   - Format message for each platform
   - Include hostname, timestamp (timezone-aware), log excerpt
   - Retry on failure (configurable retries and delays)
   - Log success/failure to syslog

4. **Clean Exit**
   - Return appropriate exit code
   - Clean up temporary files

### Security

- **Local secrets**: File is `chmod 600` (root read/write only)
- **Doppler secrets**: Service token embedded in systemd Environment directives
- **No passwords in logs**: All credentials are redacted from log output
- **HTTPS only**: All webhook calls use secure connections

## License

**Dual License:** MPL-2.0 OR Commercial

- **Open Source Use:** Licensed under the Mozilla Public License 2.0 (MPL-2.0)
- **Commercial Use:** IF planning on modifying, requires contacting [@ChiefGyk3D](https://github.com/ChiefGyk3D)
  - Most requests approved free of charge with the condition that improvements be contributed back
  - See [LICENSE](LICENSE) for full details

## Contributing

Issues and pull requests welcome! By contributing, you agree to license your contributions under the same dual license (MPL-2.0 / Commercial).

**Ways to contribute:**
- 🐛 Report bugs
- 💡 Suggest features
- 📖 Improve documentation
- 🔧 Submit code improvements
- ⭐ Star the repository
- 📢 Share with others

---

## 💬 Community & Support

### Community Channels

- **[GitHub Discussions](https://github.com/ChiefGyk3D/Patch-Gremlin/discussions)** - Ask questions, share setups
- **[GitHub Issues](https://github.com/ChiefGyk3D/Patch-Gremlin/issues)** - Bug reports and feature requests
- **[Discord Server](https://discord.chiefgyk3d.com)** - Real-time chat and support
- **[Matrix Space](https://matrix-invite.chiefgyk3d.com)** - Federated chat alternative

### Stay Updated

- **Watch releases** - Get notified of new versions
- **Follow development** - Track progress on roadmap
- **Join discussions** - Participate in feature planning

---

## 💝 Support Development

If you find Patch Gremlin useful, consider supporting development:

### Recurring Support

<div align="center">
  <table>
    <tr>
      <td align="center"><a href="https://patreon.com/chiefgyk3d?utm_medium=unknown&utm_source=join_link&utm_campaign=creatorshare_creator&utm_content=copyLink" title="Patreon"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/patreon.svg" width="32" height="32" alt="Patreon"/></a></td>
      <td align="center"><a href="https://streamelements.com/chiefgyk3d/tip" title="StreamElements"><img src="media/streamelements.png" width="32" height="32" alt="StreamElements"/></a></td>
    </tr>
    <tr>
      <td align="center">Patreon</td>
      <td align="center">StreamElements</td>
    </tr>
  </table>
</div>

### Cryptocurrency Tips

<div align="center">
  <table style="border:none;">
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/bitcoin.svg" width="28" height="28" alt="Bitcoin"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Bitcoin</b><br/>
        <code style="font-size:12px;">bc1qztdzcy2wyavj2tsuandu4p0tcklzttvdnzalla</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/monero.svg" width="28" height="28" alt="Monero"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Monero</b><br/>
        <code style="font-size:12px;">84Y34QubRwQYK2HNviezeH9r6aRcPvgWmKtDkN3EwiuVbp6sNLhm9ffRgs6BA9X1n9jY7wEN16ZEpiEngZbecXseUrW8SeQ</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/ethereum.svg" width="28" height="28" alt="Ethereum"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Ethereum</b><br/>
        <code style="font-size:12px;">0x554f18cfB684889c3A60219BDBE7b050C39335ED</code>
      </td>
    </tr>
  </table>
</div>

---

<div align="center">

Made with ❤️ by [ChiefGyk3D](https://github.com/ChiefGyk3D)

## Author & Socials

<table>
  <tr>
    <td align="center"><a href="https://social.chiefgyk3d.com/@chiefgyk3d" title="Mastodon"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/mastodon.svg" width="32" height="32" alt="Mastodon"/></a></td>
    <td align="center"><a href="https://bsky.app/profile/chiefgyk3d.com" title="Bluesky"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/bluesky.svg" width="32" height="32" alt="Bluesky"/></a></td>
    <td align="center"><a href="http://twitch.tv/chiefgyk3d" title="Twitch"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/twitch.svg" width="32" height="32" alt="Twitch"/></a></td>
    <td align="center"><a href="https://www.youtube.com/channel/UCvFY4KyqVBuYd7JAl3NRyiQ" title="YouTube"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/youtube.svg" width="32" height="32" alt="YouTube"/></a></td>
    <td align="center"><a href="https://kick.com/chiefgyk3d" title="Kick"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/kick.svg" width="32" height="32" alt="Kick"/></a></td>
    <td align="center"><a href="https://www.tiktok.com/@chiefgyk3d" title="TikTok"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/tiktok.svg" width="32" height="32" alt="TikTok"/></a></td>
    <td align="center"><a href="https://discord.chiefgyk3d.com" title="Discord"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/discord.svg" width="32" height="32" alt="Discord"/></a></td>
    <td align="center"><a href="https://matrix-invite.chiefgyk3d.com" title="Matrix"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/matrix.svg" width="32" height="32" alt="Matrix"/></a></td>
  </tr>
  <tr>
    <td align="center">Mastodon</td>
    <td align="center">Bluesky</td>
    <td align="center">Twitch</td>
    <td align="center">YouTube</td>
    <td align="center">Kick</td>
    <td align="center">TikTok</td>
    <td align="center">Discord</td>
    <td align="center">Matrix</td>
  </tr>
</table>

<sub>ChiefGyk3D is the author of Patch Gremlin</sub>

</div>
