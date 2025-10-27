#!/bin/bash

# Patch Gremlin - Configuration Template
# Copy this file to config.sh and customize your Doppler secret names
# https://github.com/ChiefGyk3D/Patch-Gremlin

# Configure one or more messaging platforms (any combination works!)

# Discord (webhook-based)
export DOPPLER_DISCORD_SECRET="SYSTEM_UPDATE_DISCORD"

# Microsoft Teams (webhook-based)
export DOPPLER_TEAMS_SECRET="SYSTEM_UPDATE_TEAMS"

# Slack (webhook-based)
export DOPPLER_SLACK_SECRET="SYSTEM_UPDATE_SLACK"

# Matrix - Two methods available:
# Method 1: Webhook (if you have a custom webhook integration)
export DOPPLER_MATRIX_SECRET="SYSTEM_UPDATE_MATRIX"

# Method 2: Matrix Client-Server API (recommended - requires 4 secrets)
export DOPPLER_MATRIX_HOMESERVER_SECRET="MATRIX_HOMESERVER"
export DOPPLER_MATRIX_USERNAME_SECRET="MATRIX_USERNAME"
export DOPPLER_MATRIX_PASSWORD_SECRET="MATRIX_PASSWORD"
export DOPPLER_MATRIX_ROOM_ID_SECRET="SYSTEM_UPDATE_MATRIX_ROOM"

# Examples of custom naming:
# export DOPPLER_DISCORD_SECRET="SYSUPDATE_DISCORD_WEBHOOK"
# export DOPPLER_TEAMS_SECRET="SYSUPDATE_TEAMS_WEBHOOK"
# export DOPPLER_SLACK_SECRET="SYSUPDATE_SLACK_WEBHOOK"

# Or namespace by hostname:
# export DOPPLER_DISCORD_SECRET="$(hostname)_UPDATE_DISCORD"
# export DOPPLER_TEAMS_SECRET="$(hostname)_UPDATE_TEAMS"
# export DOPPLER_SLACK_SECRET="$(hostname)_UPDATE_SLACK"

# Or by environment:
# export DOPPLER_DISCORD_SECRET="PROD_UPDATE_DISCORD"
# export DOPPLER_TEAMS_SECRET="PROD_UPDATE_TEAMS"
# export DOPPLER_SLACK_SECRET="PROD_UPDATE_SLACK"

