# Troubleshooting Guide

## Common Issues

### 1. Config Not Loading

**Symptom**: Script shows default secret names instead of your custom names

**Solution**:
```bash
# Ensure config exists
ls -la /etc/update-notifier/config.sh

# If missing, copy it
sudo cp ~/src/scripts/config.sh /etc/update-notifier/config.sh
sudo chmod 644 /etc/update-notifier/config.sh

# Test
sudo /usr/local/bin/update-notifier.sh
```

### 2. Doppler Authentication Failed

**Symptom**: `Error: No notification methods configured in Doppler`

**Solution**:
```bash
# Re-authenticate as root
sudo doppler login

# Setup project
sudo doppler setup --project your-project --config your-config

# Verify
sudo doppler me
sudo doppler secrets
```

**Note**: Root and regular users have separate Doppler authentication.

### 3. Hostname Resolution Error

**Symptom**: `sudo: unable to resolve host streamer-daemon: Name or service not known`

**Solution**:
```bash
# Edit /etc/hosts
sudo nano /etc/hosts

# Ensure this line matches your hostname
127.0.1.1       your-hostname

# Verify
hostname
```

### 4. Matrix Login Failed

**Symptom**: `Failed to login to Matrix - Invalid username or password`

**Causes**:
1. Wrong username format
2. Incorrect password
3. Wrong homeserver URL

**Solution**:
```bash
# Check username format (should be just "username", not "@username:server")
sudo doppler secrets get MATRIX_USERNAME --plain

# Update if needed
doppler secrets set MATRIX_USERNAME="username"  # No @ or :server

# Check homeserver
sudo doppler secrets get MATRIX_HOMESERVER --plain

# Verify password
sudo doppler secrets get MATRIX_PASSWORD --plain
```

### 5. Discord Invalid JSON Error

**Symptom**: `Failed to send notification to Discord (HTTP 400) - Invalid JSON`

**Cause**: Special characters in log output breaking JSON format

**Solution**: This is now fixed in the latest version. Update your script:
```bash
sudo cp ~/src/scripts/update-notifier.sh /usr/local/bin/update-notifier.sh
sudo chmod +x /usr/local/bin/update-notifier.sh
```

### 6. No Security Updates Available

**Symptom**: `unattended-upgrade` runs but installs nothing

**This is normal!** It means your system is up to date.

**Test with dry-run**:
```bash
sudo unattended-upgrade --dry-run --debug
```

Look for: `pkgs that look like they should be upgraded:`

### 7. Config Lost After SSH

**Symptom**: Config works locally but not over SSH

**Cause**: Environment variables don't transfer over SSH

**Solution**: The script now auto-loads from `/etc/update-notifier/config.sh`. Ensure it exists:
```bash
sudo cp ~/src/scripts/config.sh /etc/update-notifier/config.sh
```

### 8. Permission Denied

**Symptom**: Permission errors when running scripts

**Solution**:
```bash
# Make scripts executable
chmod +x setup-unattended-upgrades.sh
chmod +x test-setup.sh
chmod +x uninstall.sh

# Notification script needs root
sudo chmod +x /usr/local/bin/update-notifier.sh
```

## Verification Commands

```bash
# 1. Check Doppler auth
sudo doppler me

# 2. List secrets
sudo doppler secrets

# 3. Check config file
cat /etc/update-notifier/config.sh

# 4. Test notification
sudo /usr/local/bin/update-notifier.sh

# 5. Check systemd services
sudo systemctl status update-notifier.service
sudo systemctl status update-notifier.timer

# 6. View logs
sudo journalctl -u update-notifier.service -n 50
tail -f /var/log/unattended-upgrades/unattended-upgrades.log
```

## Debug Mode

Add debug output to the notification script:

```bash
# Edit the script
sudo nano /usr/local/bin/update-notifier.sh

# Add after #!/bin/bash
set -x  # Enable debug mode

# Run and see detailed output
sudo /usr/local/bin/update-notifier.sh
```

## Reset Everything

If all else fails, start fresh:

```bash
# 1. Uninstall
sudo ./uninstall.sh

# 2. Re-authenticate Doppler
sudo doppler login
sudo doppler setup --project your-project --config your-config

# 3. Verify secrets
sudo doppler secrets

# 4. Update config.sh if needed
nano config.sh

# 5. Reinstall
sudo ./setup-unattended-upgrades.sh
```

## Getting Help

When asking for help, include:

1. Output of `./test-setup.sh`
2. Output of `sudo doppler me`
3. Error messages from the script
4. System info: `uname -a` and `cat /etc/os-release`
