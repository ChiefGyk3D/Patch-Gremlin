#!/bin/bash
#
# Patch Gremlin - Doppler secret-name overrides
# Copy to config.sh and edit if your Doppler secrets are named differently.
# https://github.com/ChiefGyk3D/Patch-Gremlin
#
# SECURITY NOTE
# -------------
# This file is PARSED, not executed. Only `KEY=VALUE` lines whose key appears
# in the installer's allowlist are read, and values containing shell
# metacharacters ($ ` ; & | < > ( )) are rejected rather than evaluated.
#
# That means command substitution does NOT work here. A previous version of
# this template suggested `export DOPPLER_DISCORD_SECRET="$(hostname)_..."`,
# which the old loader executed as root. If you want per-host secret names,
# set the variable in the environment instead:
#
#   sudo -E env DOPPLER_DISCORD_SECRET="$(hostname)_UPDATE_DISCORD" \
#        ./setup-unattended-upgrades.sh
#
# Values here are Doppler secret NAMES, never the secrets themselves.

# --- Chat platforms -------------------------------------------------------
export DOPPLER_DISCORD_SECRET="UPDATE_NOTIFIER_DISCORD_WEBHOOK"
export DOPPLER_SLACK_SECRET="UPDATE_NOTIFIER_SLACK_WEBHOOK"
export DOPPLER_TEAMS_SECRET="UPDATE_NOTIFIER_TEAMS_WEBHOOK"

# --- Matrix ---------------------------------------------------------------
# Option 1: a custom webhook integration
export DOPPLER_MATRIX_SECRET="UPDATE_NOTIFIER_MATRIX_WEBHOOK"

# Option 2 (recommended): homeserver + a long-lived access token.
# An access token avoids a fresh device being registered on every run.
export DOPPLER_MATRIX_HOMESERVER_SECRET="UPDATE_NOTIFIER_MATRIX_HOMESERVER"
export DOPPLER_MATRIX_TOKEN_SECRET="UPDATE_NOTIFIER_MATRIX_ACCESS_TOKEN"
export DOPPLER_MATRIX_ROOM_ID_SECRET="UPDATE_NOTIFIER_MATRIX_ROOM_ID"

# Option 3: username + password (a device is created and logged out each run)
export DOPPLER_MATRIX_USERNAME_SECRET="UPDATE_NOTIFIER_MATRIX_USERNAME"
export DOPPLER_MATRIX_PASSWORD_SECRET="UPDATE_NOTIFIER_MATRIX_PASSWORD"

# --- Push / self-hosted ---------------------------------------------------
export DOPPLER_NTFY_URL_SECRET="UPDATE_NOTIFIER_NTFY_URL"
export DOPPLER_NTFY_TOPIC_SECRET="UPDATE_NOTIFIER_NTFY_TOPIC"
export DOPPLER_NTFY_TOKEN_SECRET="UPDATE_NOTIFIER_NTFY_TOKEN"
export DOPPLER_GOTIFY_URL_SECRET="UPDATE_NOTIFIER_GOTIFY_URL"
export DOPPLER_GOTIFY_TOKEN_SECRET="UPDATE_NOTIFIER_GOTIFY_TOKEN"

# --- Generic JSON webhook -------------------------------------------------
export DOPPLER_WEBHOOK_SECRET="UPDATE_NOTIFIER_WEBHOOK_URL"
