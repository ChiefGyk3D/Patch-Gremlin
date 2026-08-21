#!/bin/bash
#
# Patch Gremlin - Setup Script
# Configures automatic security updates on Debian/RHEL with notifications.
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -euo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# DESTDIR-style prefix. When set, the script stages a full install into that
# directory instead of the live system: no package installation, no root
# requirement. This is what the test-suite drives.
PG_ROOT="${PATCH_GREMLIN_ROOT:-}"
SKIP_PACKAGE_INSTALL="${PATCH_GREMLIN_SKIP_PACKAGE_INSTALL:-false}"
[[ -n "$PG_ROOT" ]] && SKIP_PACKAGE_INSTALL=true

NON_INTERACTIVE="${PATCH_GREMLIN_NON_INTERACTIVE:-false}"

say()  { echo -e "$*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
die()  { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

# Resolve a system path under the staging prefix.
p() { printf '%s%s' "$PG_ROOT" "$1"; }

# Write a file, creating parents, with an explicit mode.
write_file() {
    local path mode
    path="$(p "$1")"; mode="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    chmod "$mode" "$path"
}

run_systemctl() {
    if [[ -n "$PG_ROOT" ]]; then
        echo "systemctl $*" >> "$PG_ROOT/systemctl.log"
        return 0
    fi
    systemctl "$@"
}

usage() {
    cat <<EOF
Patch Gremlin setup v${PATCH_GREMLIN_VERSION}

Usage: sudo -E ./setup-unattended-upgrades.sh [OPTIONS]

Options:
  -y, --non-interactive   Never prompt; every setting must come from the
                          environment. Fails fast on anything missing.
  -u, --update-only       Refresh installed scripts and units, keep config.
  -h, --help              Show this help and exit
  -V, --version           Show the version and exit

Configuration environment variables (all optional in interactive mode):
  UPDATE_TYPE=security|all           What to install automatically
  UPDATE_SCHEDULE=daily|weekly       How often
  UPDATE_DAY=Sun..Sat                Day, when weekly (default: Sat)
  UPDATE_TIME=HH:MM                  24-hour local time (default: 02:00)
  SYSTEM_TIMEZONE=Area/City          Set the system timezone
  VERBOSE_LOGGING=true|false         unattended-upgrades debug output
  AUTO_REBOOT=true|false             Reboot when a update requires it
  REBOOT_WITH_USERS=true|false       Reboot even with users logged in
                                     (default: false)
  ENABLE_HEARTBEAT=true|false        Also send a scheduled report even when
                                     no upgrade ran (default: false)
  SECRET_MODE=doppler|local          Where secrets live
  DOPPLER_TOKEN=dp.st....            Required for doppler mode

Local-mode secrets (used with SECRET_MODE=local):
  LOCAL_DISCORD_WEBHOOK, LOCAL_SLACK_WEBHOOK, LOCAL_TEAMS_WEBHOOK,
  LOCAL_MATRIX_WEBHOOK, LOCAL_MATRIX_HOMESERVER, LOCAL_MATRIX_USERNAME,
  LOCAL_MATRIX_PASSWORD, LOCAL_MATRIX_ACCESS_TOKEN, LOCAL_MATRIX_ROOM_ID,
  LOCAL_NTFY_URL, LOCAL_NTFY_TOPIC, LOCAL_NTFY_TOKEN,
  LOCAL_GOTIFY_URL, LOCAL_GOTIFY_TOKEN, LOCAL_WEBHOOK_URL

Example (fully unattended):
  sudo -E env UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=03:30 \\
       SECRET_MODE=local LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/... \\
       ./setup-unattended-upgrades.sh --non-interactive
EOF
}

# ---------------------------------------------------------------------------
# Prompt helpers - refuse to block when running non-interactively.
# ---------------------------------------------------------------------------
prompt() {
    local varname="$1" message="$2" default="${3:-}" silent="${4:-false}"
    if [[ "$NON_INTERACTIVE" == "true" ]] || [[ ! -t 0 ]]; then
        if [[ -n "$default" ]]; then
            printf -v "$varname" '%s' "$default"
            return 0
        fi
        die "--non-interactive was requested but '$varname' is not set (see --help)"
    fi
    local reply
    if [[ "$silent" == "true" ]]; then
        read -rsp "$message" reply || reply=""
        echo ""
    else
        read -rp "$message" reply || reply=""
    fi
    printf -v "$varname" '%s' "${reply:-$default}"
}

# ---------------------------------------------------------------------------
# Validation - applied to preset values too, not just interactive answers.
# The old script only regex-checked UPDATE_TIME on the interactive path, so an
# env-supplied value went straight into a systemd OnCalendar= line unchecked.
# ---------------------------------------------------------------------------
validate_time() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}
validate_day() {
    [[ "$1" =~ ^(Sun|Mon|Tue|Wed|Thu|Fri|Sat)$ ]]
}
validate_timezone() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9+_-]*(/[A-Za-z0-9+._-]+)*$ ]] || return 1
    [[ -z "$PG_ROOT" ]] || return 0
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

# Add HH:MM + minutes, wrapping past midnight.
time_plus_minutes() {
    local hhmm="$1" add="$2" h m total
    h="${hhmm%%:*}"; m="${hhmm##*:}"
    total=$(( (10#$h * 60 + 10#$m + add) % 1440 ))
    printf '%02d:%02d' $(( total / 60 )) $(( total % 60 ))
}

# ---------------------------------------------------------------------------
# config.sh loading
#
# The old loader grepped out `export` lines, warned if it *saw* a command
# substitution, then sourced the file anyway - so `export X="$(cmd)"` still
# executed as root. This parses KEY=VALUE against an allowlist and never
# evaluates the file.
# ---------------------------------------------------------------------------
CONFIG_ALLOWLIST='^(DOPPLER_(DISCORD|TEAMS|SLACK|MATRIX|MATRIX_HOMESERVER|MATRIX_USERNAME|MATRIX_PASSWORD|MATRIX_ROOM_ID|MATRIX_TOKEN|NTFY_URL|NTFY_TOPIC|NTFY_TOKEN|GOTIFY_URL|GOTIFY_TOKEN|WEBHOOK)_SECRET)$'

load_config_file() {
    local config_file="$1" line key value skipped=0 loaded=0
    [[ -r "$config_file" ]] || return 1
    say "Loading configuration from $config_file"

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"

        if [[ ! "$key" =~ $CONFIG_ALLOWLIST ]]; then
            warn "Ignoring unrecognised config key: $key"
            skipped=$((skipped + 1))
            continue
        fi
        # Strip one layer of matching quotes.
        if [[ "$value" == \"*\" ]]; then value="${value:1:-1}"
        elif [[ "$value" == \'*\' ]]; then value="${value:1:-1}"
        fi
        # Values are used as Doppler secret NAMES; anything that could be
        # expanded or injected is rejected outright rather than executed.
        if [[ "$value" =~ [\$\`\;\&\|\<\>\(\)] ]]; then
            warn "Ignoring '$key': value contains shell metacharacters"
            skipped=$((skipped + 1))
            continue
        fi
        printf -v "$key" '%s' "$value"
        loaded=$((loaded + 1))
    done < "$config_file"

    ok "Loaded $loaded setting(s) from config${skipped:+, ignored $skipped}"
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found"
    local ID="" VERSION_ID="" ID_LIKE=""
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    # Debian testing/sid has no VERSION_ID; the old script read it under
    # `set -u` and aborted.
    OS_VERSION="${VERSION_ID:-rolling}"
    OS_LIKE="${ID_LIKE:-}"

    if [[ "$OS_ID" =~ ^(debian|ubuntu|raspbian)$ ]] || [[ "$OS_LIKE" =~ debian ]]; then
        OS_TYPE="debian"
        PACKAGE_MANAGER="apt-get"
    elif [[ "$OS_ID" =~ ^(rhel|centos|rocky|almalinux|fedora|amzn)$ ]] || [[ "$OS_LIKE" =~ (rhel|fedora) ]]; then
        OS_TYPE="rhel"
        # Amazon Linux 2 has no dnf; Fedora 41+ ships dnf5-automatic.
        if command -v dnf &>/dev/null; then
            PACKAGE_MANAGER="dnf"
        elif command -v yum &>/dev/null; then
            PACKAGE_MANAGER="yum"
        else
            PACKAGE_MANAGER="dnf"
        fi
    else
        die "Unsupported OS: $OS_ID (supported: Debian, Ubuntu, RHEL, Rocky, AlmaLinux, Amazon Linux, Fedora)"
    fi
}

automatic_package_name() {
    if [[ "$PACKAGE_MANAGER" == "yum" ]]; then
        echo "yum-cron"
    elif "$PACKAGE_MANAGER" list --available dnf5-automatic &>/dev/null; then
        echo "dnf5-automatic"
    else
        echo "dnf-automatic"
    fi
}

backup_file() {
    local src backup_dir stamp
    src="$(p "$1")"
    [[ -f "$src" ]] || return 0
    backup_dir="$(p /var/backups/patch-gremlin)"
    mkdir -p "$backup_dir"
    stamp="$(date +%Y%m%d-%H%M%S)"
    # Backups deliberately do NOT live in /etc/apt/apt.conf.d - APT logs an
    # "invalid filename extension" warning for every stray file there, on
    # every single apt invocation.
    cp "$src" "$backup_dir/$(basename "$1").$stamp"
    ok "Backed up $1 to /var/backups/patch-gremlin/"
}

# ---------------------------------------------------------------------------
# Debian / Ubuntu
# ---------------------------------------------------------------------------
install_debian_updates() {
    if [[ "$SKIP_PACKAGE_INSTALL" != "true" ]]; then
        say "${YELLOW}Installing unattended-upgrades...${NC}"
        apt-get update
        apt-get install -y unattended-upgrades apt-listchanges
    fi

    backup_file /etc/apt/apt.conf.d/50unattended-upgrades

    local origins
    if [[ "$UPDATE_TYPE" == "security" ]]; then
        origins='        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
        "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
        // Ubuntu Pro / ESM - LTS hosts silently skip these without them
        "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";
        "origin=UbuntuESM,archive=${distro_codename}-infra-security";'
    else
        origins='        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
        "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
        "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";
        "origin=UbuntuESM,archive=${distro_codename}-infra-security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates";
        "origin=Ubuntu,archive=${distro_codename},label=Ubuntu";
        "origin=Ubuntu,archive=${distro_codename}-updates,label=Ubuntu";'
    fi

    # Reboot an hour after the upgrade window rather than at a hardcoded 03:00,
    # which could otherwise sit ~23 hours in the future.
    local reboot_time
    reboot_time="$(time_plus_minutes "$UPDATE_TIME" 60)"

    write_file /etc/apt/apt.conf.d/50unattended-upgrades 644 <<EOF
// Managed by Patch Gremlin v${PATCH_GREMLIN_VERSION} - regenerated on setup.
Unattended-Upgrade::Origins-Pattern {
${origins}
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${reboot_time}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "${REBOOT_WITH_USERS}";

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
Unattended-Upgrade::Verbose "${VERBOSE_LOGGING}";
EOF

    local periodic_verbose=0
    [[ "$VERBOSE_LOGGING" == "true" ]] && periodic_verbose=2

    backup_file /etc/apt/apt.conf.d/20auto-upgrades
    write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "${periodic_verbose}";
EOF

    write_file /etc/systemd/system/apt-daily-upgrade.timer.d/patch-gremlin.conf 644 <<EOF
# Managed by Patch Gremlin
[Timer]
OnCalendar=
OnCalendar=$(oncalendar_expression)
RandomizedDelaySec=30min
EOF

    run_systemctl daemon-reload
    run_systemctl restart apt-daily-upgrade.timer
    ok "Configured unattended-upgrades (${UPDATE_TYPE}, ${UPDATE_SCHEDULE} at ${UPDATE_TIME}, reboot ${reboot_time})"
}

# ---------------------------------------------------------------------------
# RHEL family
# ---------------------------------------------------------------------------
install_rhel_updates() {
    local pkg
    pkg="$(automatic_package_name)"
    if [[ "$SKIP_PACKAGE_INSTALL" != "true" ]]; then
        say "${YELLOW}Installing ${pkg}...${NC}"
        "$PACKAGE_MANAGER" install -y "$pkg"
    fi

    backup_file /etc/dnf/automatic.conf

    local upgrade_type="default"
    [[ "$UPDATE_TYPE" == "security" ]] && upgrade_type="security"

    write_file /etc/dnf/automatic.conf 644 <<EOF
# Managed by Patch Gremlin v${PATCH_GREMLIN_VERSION}
[commands]
upgrade_type = ${upgrade_type}
random_sleep = 0
download_updates = yes
apply_updates = yes
reboot = $( [[ "$AUTO_REBOOT" == "true" ]] && echo "when-needed" || echo "never" )

[emitters]
emit_via = stdio

[base]
debuglevel = 1
EOF

    write_file /etc/systemd/system/dnf-automatic.timer.d/patch-gremlin.conf 644 <<EOF
# Managed by Patch Gremlin
[Timer]
OnCalendar=
OnCalendar=$(oncalendar_expression)
RandomizedDelaySec=30min
EOF

    run_systemctl daemon-reload
    run_systemctl enable --now dnf-automatic.timer
    ok "Configured ${pkg} (${UPDATE_TYPE}, ${UPDATE_SCHEDULE} at ${UPDATE_TIME})"
}

oncalendar_expression() {
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        printf '%s *-*-* %s:00' "$UPDATE_DAY" "$UPDATE_TIME"
    else
        printf '*-*-* %s:00' "$UPDATE_TIME"
    fi
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
install_secrets() {
    mkdir -p "$(p /etc/update-notifier)"
    chmod 755 "$(p /etc/update-notifier)"

    if [[ "$SECRET_MODE" == "local" ]]; then
        write_file /etc/update-notifier/secrets.conf 600 <<EOF
# Patch Gremlin local secrets. Mode 600, root-owned.
SECRET_MODE="local"

DISCORD_WEBHOOK="${LOCAL_DISCORD_WEBHOOK}"
SLACK_WEBHOOK="${LOCAL_SLACK_WEBHOOK}"
TEAMS_WEBHOOK="${LOCAL_TEAMS_WEBHOOK}"

MATRIX_WEBHOOK="${LOCAL_MATRIX_WEBHOOK}"
MATRIX_HOMESERVER="${LOCAL_MATRIX_HOMESERVER}"
MATRIX_USERNAME="${LOCAL_MATRIX_USERNAME}"
MATRIX_PASSWORD="${LOCAL_MATRIX_PASSWORD}"
MATRIX_ACCESS_TOKEN="${LOCAL_MATRIX_ACCESS_TOKEN}"
MATRIX_ROOM_ID="${LOCAL_MATRIX_ROOM_ID}"

NTFY_URL="${LOCAL_NTFY_URL}"
NTFY_TOPIC="${LOCAL_NTFY_TOPIC}"
NTFY_TOKEN="${LOCAL_NTFY_TOKEN}"

GOTIFY_URL="${LOCAL_GOTIFY_URL}"
GOTIFY_TOKEN="${LOCAL_GOTIFY_TOKEN}"

GENERIC_WEBHOOK_URL="${LOCAL_WEBHOOK_URL}"
EOF
        ok "Wrote /etc/update-notifier/secrets.conf (mode 600)"
        # Nothing sensitive in the unit file itself.
        write_file /etc/update-notifier/env 600 <<EOF
SECRET_MODE=local
EOF
    else
        # The Doppler token used to be embedded in the systemd unit AND in
        # /etc/apt/apt.conf.d/99patch-gremlin-notification, both mode 644 -
        # any local user could read it, and `systemctl show` exposed it too.
        # It now lives in one root-only EnvironmentFile.
        write_file /etc/update-notifier/env 600 <<EOF
SECRET_MODE=doppler
DOPPLER_TOKEN=${DOPPLER_TOKEN}
DOPPLER_DISCORD_SECRET=${DOPPLER_DISCORD_SECRET}
DOPPLER_TEAMS_SECRET=${DOPPLER_TEAMS_SECRET}
DOPPLER_SLACK_SECRET=${DOPPLER_SLACK_SECRET}
DOPPLER_MATRIX_SECRET=${DOPPLER_MATRIX_SECRET}
DOPPLER_MATRIX_HOMESERVER_SECRET=${DOPPLER_MATRIX_HOMESERVER_SECRET}
DOPPLER_MATRIX_USERNAME_SECRET=${DOPPLER_MATRIX_USERNAME_SECRET}
DOPPLER_MATRIX_PASSWORD_SECRET=${DOPPLER_MATRIX_PASSWORD_SECRET}
DOPPLER_MATRIX_ROOM_ID_SECRET=${DOPPLER_MATRIX_ROOM_ID_SECRET}
EOF
        ok "Wrote /etc/update-notifier/env (mode 600, root only)"
    fi
}

# ---------------------------------------------------------------------------
# Units and hooks
# ---------------------------------------------------------------------------
install_scripts() {
    [[ -f "$SCRIPT_DIR/update-notifier.sh" ]] || die "update-notifier.sh not found next to this script"
    mkdir -p "$(p /usr/local/bin)"
    install -m 755 "$SCRIPT_DIR/update-notifier.sh" "$(p /usr/local/bin/update-notifier.sh)"
    ok "Installed /usr/local/bin/update-notifier.sh"

    # Both monitoring integrations look for this path; it was previously never
    # installed, so Nagios/Prometheus checks could only ever report UNKNOWN.
    if [[ -f "$SCRIPT_DIR/health-check.sh" ]]; then
        install -m 755 "$SCRIPT_DIR/health-check.sh" "$(p /usr/local/bin/patch-gremlin-health-check.sh)"
        ok "Installed /usr/local/bin/patch-gremlin-health-check.sh"
    fi
    mkdir -p "$(p /var/lib/patch-gremlin)"
}

install_units() {
    write_file /etc/systemd/system/update-notifier.service 644 <<EOF
[Unit]
Description=Patch Gremlin update notification
Documentation=https://github.com/ChiefGyk3D/Patch-Gremlin
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/update-notifier/env
ExecStart=/usr/local/bin/update-notifier.sh
User=root
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

# Hardening - this service only reads logs and makes outbound HTTPS calls.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
ReadWritePaths=/var/lib/patch-gremlin /run
EOF
    ok "Installed update-notifier.service"

    # The notifier is triggered by the upgrade unit finishing, NOT by a timer
    # racing it. Previously both fired at UPDATE_TIME with independent
    # RandomizedDelaySec=30min, so roughly half the time the notification
    # described the *previous* run.
    local upgrade_unit
    if [[ "$OS_TYPE" == "debian" ]]; then
        upgrade_unit="apt-daily-upgrade.service"
    else
        upgrade_unit="dnf-automatic.service"
    fi

    write_file "/etc/systemd/system/${upgrade_unit}.d/patch-gremlin.conf" 644 <<EOF
# Managed by Patch Gremlin - notify once the upgrade run has finished.
[Service]
ExecStartPost=-/usr/local/bin/update-notifier.sh
EnvironmentFile=/etc/update-notifier/env
EOF
    ok "Hooked notifications onto ${upgrade_unit}"

    # Optional heartbeat timer. Note there is no Requires= in [Unit]: that
    # would make systemd activate the service the moment the timer starts,
    # firing a notification on every boot.
    write_file /etc/systemd/system/update-notifier.timer 644 <<EOF
[Unit]
Description=Patch Gremlin scheduled update report
Documentation=https://github.com/ChiefGyk3D/Patch-Gremlin

[Timer]
OnCalendar=$(heartbeat_oncalendar)
RandomizedDelaySec=15min
Persistent=true
Unit=update-notifier.service

[Install]
WantedBy=timers.target
EOF

    if [[ "$ENABLE_HEARTBEAT" == "true" ]]; then
        run_systemctl enable --now update-notifier.timer
        ok "Enabled heartbeat timer ($(heartbeat_oncalendar))"
    else
        run_systemctl disable update-notifier.timer 2>/dev/null || true
        ok "Heartbeat timer installed but disabled (set ENABLE_HEARTBEAT=true to enable)"
    fi
}

heartbeat_oncalendar() {
    # Two hours after the upgrade window so it never races the upgrade unit.
    local t
    t="$(time_plus_minutes "$UPDATE_TIME" 120)"
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        printf '%s *-*-* %s:00' "$UPDATE_DAY" "$t"
    else
        printf '*-*-* %s:00' "$t"
    fi
}

remove_legacy_artifacts() {
    # v1 embedded the Doppler token in a world-readable APT hook that also
    # fired after EVERY dpkg invocation, so `apt install htop` sent a
    # notification. Remove it on upgrade.
    local hook
    hook="$(p /etc/apt/apt.conf.d/99patch-gremlin-notification)"
    if [[ -f "$hook" ]]; then
        rm -f "$hook"
        ok "Removed legacy APT Dpkg::Post-Invoke hook (fired on every apt run)"
    fi
    local old_dnf
    old_dnf="$(p /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf)"
    if [[ -f "$old_dnf" ]] && grep -q 'DOPPLER_TOKEN' "$old_dnf" 2>/dev/null; then
        rm -f "$old_dnf"
        ok "Removed legacy dnf drop-in containing an inline Doppler token"
    fi
    # Old backups dumped into apt.conf.d make APT warn on every invocation.
    local d
    d="$(p /etc/apt/apt.conf.d)"
    if compgen -G "$d/*.backup.*" >/dev/null 2>&1; then
        mkdir -p "$(p /var/backups/patch-gremlin)"
        mv "$d"/*.backup.* "$(p /var/backups/patch-gremlin)/" 2>/dev/null || true
        ok "Moved stray APT backups out of apt.conf.d"
    fi
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------
gather_settings() {
    UPDATE_TYPE="${UPDATE_TYPE:-}"
    UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-}"
    # Always defaulted: a preset UPDATE_SCHEDULE=weekly with no UPDATE_DAY
    # used to abort mid-install with "UPDATE_DAY: unbound variable", after
    # the apt config had already been rewritten.
    UPDATE_DAY="${UPDATE_DAY:-Sat}"
    UPDATE_TIME="${UPDATE_TIME:-02:00}"
    SYSTEM_TIMEZONE="${SYSTEM_TIMEZONE:-}"
    VERBOSE_LOGGING="${VERBOSE_LOGGING:-}"
    AUTO_REBOOT="${AUTO_REBOOT:-}"
    REBOOT_WITH_USERS="${REBOOT_WITH_USERS:-false}"
    ENABLE_HEARTBEAT="${ENABLE_HEARTBEAT:-false}"
    SECRET_MODE="${SECRET_MODE:-}"

    if [[ -z "$UPDATE_TYPE" ]]; then
        say "\n${YELLOW}Update scope:${NC}\n  1) Security updates only (recommended)\n  2) All available updates"
        prompt REPLY_TYPE "Enter choice [1-2] (default: 1): " "1"
        [[ "$REPLY_TYPE" == "2" ]] && UPDATE_TYPE="all" || UPDATE_TYPE="security"
    fi
    [[ "$UPDATE_TYPE" =~ ^(security|all)$ ]] || die "UPDATE_TYPE must be 'security' or 'all' (got '$UPDATE_TYPE')"

    if [[ -z "$UPDATE_SCHEDULE" ]]; then
        say "\n${YELLOW}Schedule:${NC}\n  1) Daily (recommended)\n  2) Weekly"
        prompt REPLY_SCHED "Enter choice [1-2] (default: 1): " "1"
        [[ "$REPLY_SCHED" == "2" ]] && UPDATE_SCHEDULE="weekly" || UPDATE_SCHEDULE="daily"
        if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
            prompt UPDATE_DAY "Day of week [Sun-Sat] (default: Sat): " "Sat"
        fi
        prompt UPDATE_TIME "Time in 24-hour HH:MM (default: 02:00): " "02:00"
    fi
    [[ "$UPDATE_SCHEDULE" =~ ^(daily|weekly)$ ]] || die "UPDATE_SCHEDULE must be 'daily' or 'weekly' (got '$UPDATE_SCHEDULE')"
    validate_day "$UPDATE_DAY" || die "UPDATE_DAY must be one of Sun Mon Tue Wed Thu Fri Sat (got '$UPDATE_DAY')"
    validate_time "$UPDATE_TIME" || die "UPDATE_TIME must be HH:MM in 24-hour form (got '$UPDATE_TIME')"

    if [[ -z "$VERBOSE_LOGGING" ]]; then
        prompt REPLY_VERBOSE "Enable verbose unattended-upgrades logging? (y/N): " "n"
        [[ "$REPLY_VERBOSE" =~ ^[Yy] ]] && VERBOSE_LOGGING="true" || VERBOSE_LOGGING="false"
    fi
    if [[ -z "$AUTO_REBOOT" ]]; then
        prompt REPLY_REBOOT "Reboot automatically when an update requires it? (Y/n): " "y"
        [[ "$REPLY_REBOOT" =~ ^[Nn] ]] && AUTO_REBOOT="false" || AUTO_REBOOT="true"
        if [[ "$AUTO_REBOOT" == "true" ]]; then
            # Previously hardcoded to "true", so a box could reboot out from
            # under logged-in users without the operator ever being asked.
            prompt REPLY_WITHUSERS "Reboot even when users are logged in? (y/N): " "n"
            [[ "$REPLY_WITHUSERS" =~ ^[Yy] ]] && REBOOT_WITH_USERS="true" || REBOOT_WITH_USERS="false"
        fi
    fi
    [[ "$VERBOSE_LOGGING" =~ ^(true|false)$ ]] || die "VERBOSE_LOGGING must be true or false"
    [[ "$AUTO_REBOOT" =~ ^(true|false)$ ]] || die "AUTO_REBOOT must be true or false"
    [[ "$REBOOT_WITH_USERS" =~ ^(true|false)$ ]] || die "REBOOT_WITH_USERS must be true or false"
    [[ "$ENABLE_HEARTBEAT" =~ ^(true|false)$ ]] || die "ENABLE_HEARTBEAT must be true or false"

    if [[ -z "$SECRET_MODE" ]]; then
        say "\n${YELLOW}Secret storage:${NC}\n  1) Doppler\n  2) Local file (/etc/update-notifier/secrets.conf)"
        prompt REPLY_SECRET "Enter choice [1-2] (default: 1): " "1"
        [[ "$REPLY_SECRET" == "2" ]] && SECRET_MODE="local" || SECRET_MODE="doppler"
    fi
    [[ "$SECRET_MODE" =~ ^(doppler|local)$ ]] || die "SECRET_MODE must be 'doppler' or 'local' (got '$SECRET_MODE')"
}

apply_timezone() {
    # SYSTEM_TIMEZONE was documented in the README but the preset path only
    # printed "Using preset timezone configuration" and never applied it.
    [[ -n "$SYSTEM_TIMEZONE" ]] || return 0
    validate_timezone "$SYSTEM_TIMEZONE" || die "SYSTEM_TIMEZONE '$SYSTEM_TIMEZONE' is not a valid zone name"
    if [[ -n "$PG_ROOT" ]]; then
        mkdir -p "$(p /etc)"
        echo "$SYSTEM_TIMEZONE" > "$(p /etc/timezone)"
        ok "Timezone staged as $SYSTEM_TIMEZONE"
        return 0
    fi
    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$SYSTEM_TIMEZONE" || die "Failed to set timezone to $SYSTEM_TIMEZONE"
    else
        ln -sf "/usr/share/zoneinfo/$SYSTEM_TIMEZONE" /etc/localtime
        echo "$SYSTEM_TIMEZONE" > /etc/timezone
    fi
    ok "Timezone set to $SYSTEM_TIMEZONE ($(date))"
}

gather_local_secrets() {
    LOCAL_DISCORD_WEBHOOK="${LOCAL_DISCORD_WEBHOOK:-}"
    LOCAL_SLACK_WEBHOOK="${LOCAL_SLACK_WEBHOOK:-}"
    LOCAL_TEAMS_WEBHOOK="${LOCAL_TEAMS_WEBHOOK:-}"
    LOCAL_MATRIX_WEBHOOK="${LOCAL_MATRIX_WEBHOOK:-}"
    LOCAL_MATRIX_HOMESERVER="${LOCAL_MATRIX_HOMESERVER:-}"
    LOCAL_MATRIX_USERNAME="${LOCAL_MATRIX_USERNAME:-}"
    LOCAL_MATRIX_PASSWORD="${LOCAL_MATRIX_PASSWORD:-}"
    LOCAL_MATRIX_ACCESS_TOKEN="${LOCAL_MATRIX_ACCESS_TOKEN:-}"
    LOCAL_MATRIX_ROOM_ID="${LOCAL_MATRIX_ROOM_ID:-}"
    LOCAL_NTFY_URL="${LOCAL_NTFY_URL:-}"
    LOCAL_NTFY_TOPIC="${LOCAL_NTFY_TOPIC:-}"
    LOCAL_NTFY_TOKEN="${LOCAL_NTFY_TOKEN:-}"
    LOCAL_GOTIFY_URL="${LOCAL_GOTIFY_URL:-}"
    LOCAL_GOTIFY_TOKEN="${LOCAL_GOTIFY_TOKEN:-}"
    LOCAL_WEBHOOK_URL="${LOCAL_WEBHOOK_URL:-}"

    [[ "$SECRET_MODE" == "local" ]] || return 0

    local configured="${LOCAL_DISCORD_WEBHOOK}${LOCAL_SLACK_WEBHOOK}${LOCAL_TEAMS_WEBHOOK}${LOCAL_MATRIX_WEBHOOK}${LOCAL_MATRIX_HOMESERVER}${LOCAL_NTFY_URL}${LOCAL_GOTIFY_URL}${LOCAL_WEBHOOK_URL}"
    if [[ -n "$configured" ]]; then
        ok "Using notification endpoints from the environment"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" == "true" ]] || [[ ! -t 0 ]]; then
        die "SECRET_MODE=local requires at least one LOCAL_*_WEBHOOK/URL variable in non-interactive mode (see --help)"
    fi

    say "\n${YELLOW}Notification endpoints${NC} (leave blank to skip):"
    prompt LOCAL_DISCORD_WEBHOOK "Discord webhook URL: " ""
    prompt LOCAL_SLACK_WEBHOOK   "Slack webhook URL: " ""
    prompt LOCAL_TEAMS_WEBHOOK   "Teams webhook URL: " ""
    prompt LOCAL_NTFY_URL        "ntfy server URL (e.g. https://ntfy.sh): " ""
    [[ -n "$LOCAL_NTFY_URL" ]] && prompt LOCAL_NTFY_TOPIC "ntfy topic: " ""
    prompt LOCAL_GOTIFY_URL      "Gotify message URL: " ""
    [[ -n "$LOCAL_GOTIFY_URL" ]] && prompt LOCAL_GOTIFY_TOKEN "Gotify app token: " ""

    say "\n${YELLOW}Matrix${NC}\n  1) Skip  2) Webhook  3) Homeserver + access token  4) Homeserver + password"
    prompt MATRIX_CHOICE "Enter choice [1-4] (default: 1): " "1"
    case "$MATRIX_CHOICE" in
        2) prompt LOCAL_MATRIX_WEBHOOK "Matrix webhook URL: " "" ;;
        3) prompt LOCAL_MATRIX_HOMESERVER "Homeserver (https://matrix.org): " ""
           prompt LOCAL_MATRIX_ACCESS_TOKEN "Access token: " "" "true"
           prompt LOCAL_MATRIX_ROOM_ID "Room ID (!room:server): " "" ;;
        4) prompt LOCAL_MATRIX_HOMESERVER "Homeserver (https://matrix.org): " ""
           prompt LOCAL_MATRIX_USERNAME "Username (@user:server): " ""
           prompt LOCAL_MATRIX_PASSWORD "Password: " "" "true"
           prompt LOCAL_MATRIX_ROOM_ID "Room ID (!room:server): " "" ;;
    esac

    configured="${LOCAL_DISCORD_WEBHOOK}${LOCAL_SLACK_WEBHOOK}${LOCAL_TEAMS_WEBHOOK}${LOCAL_MATRIX_WEBHOOK}${LOCAL_MATRIX_HOMESERVER}${LOCAL_NTFY_URL}${LOCAL_GOTIFY_URL}${LOCAL_WEBHOOK_URL}"
    [[ -n "$configured" ]] || die "At least one notification method must be configured"
    ok "Notification endpoints collected"
}

ensure_doppler() {
    [[ "$SECRET_MODE" == "doppler" ]] || return 0
    DOPPLER_TOKEN="${DOPPLER_TOKEN:-}"
    if [[ -z "$DOPPLER_TOKEN" ]]; then
        prompt DOPPLER_TOKEN "Doppler service token (dp.st....): " "" "true"
    fi
    [[ -n "$DOPPLER_TOKEN" ]] || die "DOPPLER_TOKEN is required when SECRET_MODE=doppler"
    [[ "$DOPPLER_TOKEN" =~ ^dp\.st\. ]] || warn "Token does not start with 'dp.st.' - it may not be a service token"

    if [[ "$SKIP_PACKAGE_INSTALL" == "true" ]]; then
        return 0
    fi
    command -v doppler &>/dev/null && return 0

    say "${YELLOW}Installing Doppler CLI...${NC}"
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg
        curl -sLf --retry 3 --tlsv1.2 --proto "=https" \
            'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' \
            | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" \
            > /etc/apt/sources.list.d/doppler-cli.list
        apt-get update && apt-get install -y doppler
    else
        rpm --import 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key'
        curl -sLf --retry 3 --tlsv1.2 --proto "=https" \
            'https://packages.doppler.com/public/cli/config.rpm.txt' > /etc/yum.repos.d/doppler-cli.repo
        "$PACKAGE_MANAGER" install -y doppler
    fi
    command -v doppler &>/dev/null || die "Failed to install the Doppler CLI - see https://docs.doppler.com/docs/install-cli"
    ok "Doppler CLI installed"
}

verify_install() {
    say "\n${YELLOW}Verifying...${NC}"
    local notifier
    notifier="$(p /usr/local/bin/update-notifier.sh)"
    if [[ -x "$notifier" ]]; then
        if PATCH_GREMLIN_DRY_RUN=true \
           PATCH_GREMLIN_SECRETS_FILE="$(p /etc/update-notifier/secrets.conf)" \
           PATCH_GREMLIN_STATE_DIR="$(p /var/lib/patch-gremlin)" \
           "$notifier" &>/dev/null; then
            ok "Notification dry-run succeeded"
        else
            warn "Notification dry-run failed - check secrets with: sudo $SCRIPT_DIR/diagnose-config.sh"
        fi
    fi

    local env_file
    env_file="$(p /etc/update-notifier/env)"
    if [[ -f "$env_file" ]]; then
        local mode
        mode="$(stat -c '%a' "$env_file")"
        [[ "$mode" == "600" ]] && ok "Secret environment file is mode 600" \
                               || warn "Secret environment file is mode $mode, expected 600"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local update_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--non-interactive) NON_INTERACTIVE=true ;;
            -u|--update-only)     update_only=true ;;
            -h|--help)            usage; exit 0 ;;
            -V|--version)         echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    say "${BLUE}=== Patch Gremlin Setup v${PATCH_GREMLIN_VERSION} ===${NC}"

    if [[ -z "$PG_ROOT" && $EUID -ne 0 ]]; then
        die "This script must be run as root. Try: sudo -E $0"
    fi

    detect_os
    ok "Detected $OS_ID $OS_VERSION (type: $OS_TYPE, pkg: $PACKAGE_MANAGER)"

    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
        load_config_file "$SCRIPT_DIR/config.sh" || true
    elif [[ -f "$(p /etc/update-notifier/config.sh)" ]]; then
        load_config_file "$(p /etc/update-notifier/config.sh)" || true
    fi

    DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
    DOPPLER_TEAMS_SECRET="${DOPPLER_TEAMS_SECRET:-UPDATE_NOTIFIER_TEAMS_WEBHOOK}"
    DOPPLER_SLACK_SECRET="${DOPPLER_SLACK_SECRET:-UPDATE_NOTIFIER_SLACK_WEBHOOK}"
    DOPPLER_MATRIX_SECRET="${DOPPLER_MATRIX_SECRET:-UPDATE_NOTIFIER_MATRIX_WEBHOOK}"
    DOPPLER_MATRIX_HOMESERVER_SECRET="${DOPPLER_MATRIX_HOMESERVER_SECRET:-UPDATE_NOTIFIER_MATRIX_HOMESERVER}"
    DOPPLER_MATRIX_USERNAME_SECRET="${DOPPLER_MATRIX_USERNAME_SECRET:-UPDATE_NOTIFIER_MATRIX_USERNAME}"
    DOPPLER_MATRIX_PASSWORD_SECRET="${DOPPLER_MATRIX_PASSWORD_SECRET:-UPDATE_NOTIFIER_MATRIX_PASSWORD}"
    DOPPLER_MATRIX_ROOM_ID_SECRET="${DOPPLER_MATRIX_ROOM_ID_SECRET:-UPDATE_NOTIFIER_MATRIX_ROOM_ID}"

    # --update-only refreshes scripts AND units/hooks. The old option 2 copied
    # only update-notifier.sh, so a version that changed the unit layout left
    # a half-upgraded install behind.
    if [[ "$update_only" == "true" ]]; then
        say "${GREEN}Refreshing installed components...${NC}"
        install_scripts
        remove_legacy_artifacts
        run_systemctl daemon-reload
        ok "Scripts and units refreshed; configuration untouched"
        exit 0
    fi

    gather_settings
    apply_timezone
    gather_local_secrets
    ensure_doppler

    remove_legacy_artifacts
    if [[ "$OS_TYPE" == "debian" ]]; then
        install_debian_updates
    else
        install_rhel_updates
    fi
    install_scripts
    install_secrets
    install_units
    run_systemctl daemon-reload
    verify_install

    say "\n${GREEN}🎉 Patch Gremlin installation complete!${NC}"
    say "\n${BLUE}What happens next:${NC}"
    say "• ${UPDATE_TYPE} updates install ${UPDATE_SCHEDULE} at ${UPDATE_TIME}"
    say "• A notification is sent when the upgrade run finishes"
    if [[ "$ENABLE_HEARTBEAT" == "true" ]]; then
        say "• A scheduled report also runs at $(time_plus_minutes "$UPDATE_TIME" 120)"
    fi
    say "\n${BLUE}Quick commands:${NC}"
    say "• Test a notification:  sudo /usr/local/bin/update-notifier.sh --dry-run"
    say "• Health check:         sudo /usr/local/bin/patch-gremlin-health-check.sh"
    say "• Diagnose config:      sudo $SCRIPT_DIR/diagnose-config.sh"
    say "• View logs:            sudo journalctl -t patch-gremlin --since '1 day ago'"
}

main "$@"
