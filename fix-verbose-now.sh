#!/bin/bash

# Quick fix to disable verbose logging RIGHT NOW
# Run this: sudo bash fix-verbose-now.sh

if [[ $EUID -ne 0 ]]; then
   echo "Error: Must run as root"
   echo "Run: sudo bash $0"
   exit 1
fi

echo "Fixing verbose logging..."

# Fix 50unattended-upgrades - remove commented line and add proper one
sed -i '/\/\/ Unattended-Upgrade::Verbose/d' /etc/apt/apt.conf.d/50unattended-upgrades
if ! grep -q '^Unattended-Upgrade::Verbose' /etc/apt/apt.conf.d/50unattended-upgrades; then
    echo 'Unattended-Upgrade::Verbose "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    echo "✓ Set Verbose to false in 50unattended-upgrades"
else
    sed -i 's/Unattended-Upgrade::Verbose ".*"/Unattended-Upgrade::Verbose "false"/' /etc/apt/apt.conf.d/50unattended-upgrades
    echo "✓ Updated Verbose to false in 50unattended-upgrades"
fi

# Fix 20auto-upgrades
sed -i 's/APT::Periodic::Verbose ".*"/APT::Periodic::Verbose "0"/' /etc/apt/apt.conf.d/20auto-upgrades
echo "✓ Set Verbose to 0 in 20auto-upgrades"

echo ""
echo "Done! Verbose logging disabled."
echo "Next unattended-upgrades run will be clean."
