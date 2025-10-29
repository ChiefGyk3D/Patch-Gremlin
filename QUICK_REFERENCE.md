# Patch Gremlin Quick Reference

## Installation Commands
```bash
# Basic setup
curl -sLf https://cli.doppler.com/install.sh | sh
doppler login && sudo doppler login
sudo doppler setup --project patch-gremlin --config production

# Add Discord webhook
doppler secrets set SYSTEM_UPDATE_DISCORD="https://discord.com/api/webhooks/..."

# Install system
source config.sh
sudo -E ./setup-unattended-upgrades.sh
```

## Testing Commands
```bash
# Health check
sudo ./health-check.sh

# Test notification (dry run)
sudo PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh

# Send test notification
sudo /usr/local/bin/update-notifier.sh
```

## Monitoring Commands
```bash
# Check service status
sudo systemctl status update-notifier.timer
sudo systemctl list-timers update-notifier*

# View logs
sudo journalctl -t patch-gremlin --since "1 day ago"
sudo journalctl -f -t patch-gremlin

# Check last notification
grep "SUCCESS: Notification delivery complete" /var/log/syslog | tail -1
```

## Environment Variables
```bash
PATCH_GREMLIN_DRY_RUN=true          # Test mode
PATCH_GREMLIN_MAX_LOG_LINES=100     # Log lines (default: 50)
PATCH_GREMLIN_RETRY_COUNT=5         # Retries (default: 3)
PATCH_GREMLIN_CURL_TIMEOUT=60       # Timeout (default: 30s)
```

## Troubleshooting
```bash
# Fix Doppler auth
sudo doppler login
sudo doppler setup --project your-project --config your-config

# Check config
sudo cat /etc/update-notifier/config.sh

# Manual test
sudo /usr/local/bin/update-notifier.sh
```

## File Locations
```
/usr/local/bin/update-notifier.sh          # Main script
/etc/update-notifier/config.sh             # Configuration
/etc/systemd/system/update-notifier.*      # Service files
/var/log/syslog                            # Logs (tag: patch-gremlin)
```
