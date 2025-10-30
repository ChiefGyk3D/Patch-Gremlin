# Testing Guide for Patch Gremlin

## Quick Start Testing

### 1. Run the Automated Test Suite
```bash
sudo bash test-deployment.sh
```

This will check:
- ✅ Installation completeness
- ✅ Secret storage configuration
- ✅ Systemd services status
- ✅ Timer schedules
- ✅ Manual notification test
- ✅ Update system configuration
- ✅ Hook execution
- ✅ Log analysis

---

## Manual Testing Steps

### Test 1: Verify Installation

```bash
# Check all components are installed
ls -la /usr/local/bin/update-notifier.sh
ls -la /etc/systemd/system/update-notifier.service
ls -la /etc/systemd/system/update-notifier.timer

# Debian/Ubuntu - check APT hook
cat /etc/apt/apt.conf.d/99patch-gremlin-notification

# RHEL/Rocky - check DNF hook
cat /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf
```

### Test 2: Check Secret Configuration

**For Local Mode:**
```bash
# Verify secrets file exists and has secure permissions
ls -la /etc/update-notifier/secrets.conf
# Should show: -rw------- (600)

# View (as root)
sudo cat /etc/update-notifier/secrets.conf
```

**For Doppler Mode:**
```bash
# Check systemd environment has token
sudo systemctl show update-notifier.service | grep DOPPLER

# Test doppler CLI access
sudo -i
export DOPPLER_TOKEN="your-token-here"
doppler secrets get SYSTEM_UPDATE_DISCORD
exit
```

### Test 3: Check Systemd Services

```bash
# Check service status
sudo systemctl status update-notifier.service
sudo systemctl status update-notifier.timer

# Check if timers are enabled
sudo systemctl is-enabled update-notifier.timer

# View timer schedule
sudo systemctl list-timers update-notifier.timer
sudo systemctl list-timers apt-daily-upgrade.timer    # Debian
sudo systemctl list-timers dnf-automatic.timer        # RHEL
```

### Test 4: Manual Notification Test

This sends a notification immediately:

```bash
# Trigger notification manually
sudo systemctl start update-notifier.service

# Check status
sudo systemctl status update-notifier.service

# View detailed logs
sudo journalctl -u update-notifier.service -n 50 --no-pager
```

**Expected Result:** You should receive notification(s) on your configured platform(s) showing current system update status.

### Test 5: Test Unattended Upgrades

**Debian/Ubuntu:**
```bash
# Check for available updates
sudo apt update
apt list --upgradable

# Dry run (no actual changes)
sudo unattended-upgrades --debug --dry-run

# Force immediate run (careful - this installs updates!)
sudo unattended-upgrades
```

**RHEL/Rocky/Fedora:**
```bash
# Check for available updates
sudo dnf check-update

# Test dnf-automatic (dry run)
sudo dnf-automatic --downloadupdates

# Force immediate run (careful - this installs updates!)
sudo systemctl start dnf-automatic.service
```

### Test 6: Test APT/DNF Hook

The hook triggers after package installations:

**Debian/Ubuntu:**
```bash
# Install a small package to trigger the hook
sudo apt install vim-tiny

# Check if notification was sent
sudo journalctl -xe | grep -i patch-gremlin
```

**RHEL/Rocky:**
```bash
# Install a small package
sudo dnf install vim-minimal

# Check logs
sudo journalctl -u dnf-automatic.service -n 20
```

### Test 7: Monitor Logs in Real-Time

```bash
# Watch notification service logs
sudo journalctl -u update-notifier.service -f

# Watch system update logs (Debian)
sudo journalctl -u unattended-upgrades.service -f

# Watch system update logs (RHEL)
sudo journalctl -u dnf-automatic.service -f

# Watch all Patch Gremlin activity
sudo journalctl -t patch-gremlin -f
```

---

## Verification Checklist

After running tests, verify:

- [ ] Received notification from manual test
- [ ] Notification contains system information
- [ ] Notification shows update status
- [ ] Notification lists pending/installed updates
- [ ] Timers are scheduled correctly
- [ ] Hooks trigger after package operations
- [ ] Logs show successful execution
- [ ] No error messages in logs

---

## Common Testing Scenarios

### Scenario 1: Test with Pending Updates

```bash
# Check current update status
apt list --upgradable    # Debian
dnf check-update         # RHEL

# If updates available, run notification
sudo systemctl start update-notifier.service

# Check notification - should show available updates
```

### Scenario 2: Test After Installing Updates

```bash
# Install updates
sudo apt upgrade -y      # Debian
sudo dnf upgrade -y      # RHEL

# Notification should trigger automatically via hook
# Check logs to confirm
sudo journalctl -u update-notifier.service -n 20
```

### Scenario 3: Test Timer Execution

```bash
# Check when timer will next run
sudo systemctl list-timers update-notifier.timer

# Manually trigger timer (advances to next scheduled time)
sudo systemctl start update-notifier.timer
```

### Scenario 4: Test with No Updates

```bash
# Ensure system is up to date
sudo apt update && sudo apt upgrade -y    # Debian
sudo dnf upgrade -y                       # RHEL

# Run notification
sudo systemctl start update-notifier.service

# Notification should say "system is up to date"
```

---

## Troubleshooting Tests

### If Notification Doesn't Send

1. **Check service logs:**
   ```bash
   sudo journalctl -u update-notifier.service -n 100 --no-pager
   ```

2. **Verify secrets:**
   ```bash
   # Local mode
   sudo cat /etc/update-notifier/secrets.conf
   
   # Doppler mode
   sudo systemctl show update-notifier.service | grep DOPPLER
   ```

3. **Test webhook manually:**
   ```bash
   # For Discord
   curl -X POST "YOUR_WEBHOOK_URL" \
     -H "Content-Type: application/json" \
     -d '{"content": "Test from Patch Gremlin"}'
   ```

4. **Run notifier script directly:**
   ```bash
   sudo -i
   export SECRET_MODE=local  # or configure DOPPLER_TOKEN
   /usr/local/bin/update-notifier.sh
   ```

### If Updates Don't Run

1. **Check update service status:**
   ```bash
   sudo systemctl status apt-daily-upgrade.timer    # Debian
   sudo systemctl status dnf-automatic.timer        # RHEL
   ```

2. **Check update service logs:**
   ```bash
   sudo journalctl -u unattended-upgrades.service -n 50    # Debian
   sudo journalctl -u dnf-automatic.service -n 50          # RHEL
   ```

3. **Verify configuration:**
   ```bash
   # Debian
   cat /etc/apt/apt.conf.d/50unattended-upgrades
   
   # RHEL
   cat /etc/dnf/automatic.conf
   ```

---

## Performance Testing

### Test Notification Delivery Time

```bash
#!/bin/bash
echo "Testing notification delivery speed..."
start=$(date +%s)
sudo systemctl start update-notifier.service
# Wait for service to complete
while systemctl is-active update-notifier.service &>/dev/null; do
    sleep 0.5
done
end=$(date +%s)
echo "Notification sent in $((end - start)) seconds"
```

### Test Multiple Rapid Notifications

```bash
# Test 3 rapid notifications
for i in {1..3}; do
    echo "Test $i"
    sudo systemctl start update-notifier.service
    sleep 5
done
```

---

## Testing on Remote Systems (Raspberry Pi, etc.)

```bash
# SSH to remote system
ssh user@raspberry-pi

# Pull latest changes
cd /path/to/Patch-Gremlin
git pull

# Run deployment test
sudo bash test-deployment.sh

# Monitor logs remotely
sudo journalctl -u update-notifier.service -f
```

---

## Automated Testing Schedule

Create a test cron job to verify regular operation:

```bash
# Add to crontab (runs every Monday at 10am)
sudo crontab -e

# Add line:
0 10 * * 1 /usr/local/bin/update-notifier.sh
```

---

## Success Criteria

Your Patch Gremlin installation is working correctly if:

1. ✅ All test scripts pass without errors
2. ✅ Manual notification test sends notification
3. ✅ Notifications contain accurate system information
4. ✅ Timers are scheduled and running
5. ✅ Hooks trigger after package operations
6. ✅ Logs show no errors
7. ✅ Both modes (Doppler/Local) work as configured
8. ✅ Notifications work for all configured platforms

---

## Questions to Verify

- **Did you receive the test notification?** Check Discord/Teams/Slack/Matrix
- **Does the notification show correct hostname?**
- **Does it list pending updates (if any)?**
- **Are the timestamps accurate?**
- **Does it trigger after installing packages?**
- **Does the timer show next execution time?**

If you can answer YES to all these, your installation is working perfectly! 🎉
