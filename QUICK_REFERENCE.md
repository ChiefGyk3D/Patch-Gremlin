# Quick Reference

## Installation

```bash
# 1. Install Doppler
curl -sLf https://cli.doppler.com/install.sh | sh

# 2. Authenticate
doppler login
sudo doppler login

# 3. Setup project
sudo doppler setup --project your-project --config your-config

# 4. Configure secrets (customize names as needed)
cp config.example.sh config.sh
nano config.sh

# 5. Run setup
sudo ./setup-unattended-upgrades.sh
```

## Testing

```bash
# Test setup
./test-setup.sh

# Test notification
sudo /usr/local/bin/update-notifier.sh

# Dry run security updates
sudo unattended-upgrade --dry-run --debug
```

## Doppler Commands

```bash
# View configuration
doppler me
sudo doppler me

# List secrets
doppler secrets
sudo doppler secrets

# Get specific secret
doppler secrets get SYSTEM_UPDATE_DISCORD --plain
sudo doppler secrets get MATRIX_USERNAME --plain

# Add/update secrets
doppler secrets set SYSTEM_UPDATE_DISCORD="https://discord.com/api/webhooks/..."
doppler secrets set MATRIX_HOMESERVER="https://matrix.chiefgyk3d.com"
doppler secrets set MATRIX_USERNAME="username"
doppler secrets set MATRIX_PASSWORD="password"
doppler secrets set SYSTEM_UPDATE_MATRIX_ROOM="!roomid:server.com"
```

## Systemd Commands

```bash
# Check service status
sudo systemctl status update-notifier.service
sudo systemctl status update-notifier.timer

# View timer schedule
sudo systemctl list-timers update-notifier.timer

# Manually trigger notification
sudo systemctl start update-notifier.service

# View logs
sudo journalctl -u update-notifier.service -n 50
sudo journalctl -u update-notifier.timer -n 20
```

## File Locations

```
/usr/local/bin/update-notifier.sh          # Main script
/etc/update-notifier/config.sh             # Secret name config
/etc/systemd/system/update-notifier.service
/etc/systemd/system/update-notifier.timer
/etc/apt/apt.conf.d/99discord-notification
/etc/apt/apt.conf.d/50unattended-upgrades
/var/log/unattended-upgrades/              # Update logs
```

## Troubleshooting

```bash
# Re-authenticate Doppler
sudo doppler login
sudo doppler setup --project your-project --config your-config

# Reinstall config
sudo cp config.sh /etc/update-notifier/config.sh

# Check logs
tail -f /var/log/unattended-upgrades/unattended-upgrades.log
sudo journalctl -u update-notifier.service -f

# Fix hostname resolution
sudo nano /etc/hosts  # Update 127.0.1.1 line

# Verify Matrix credentials
sudo doppler secrets get MATRIX_USERNAME --plain
sudo doppler secrets get MATRIX_HOMESERVER --plain
```

## Uninstallation

```bash
sudo ./uninstall.sh
```
