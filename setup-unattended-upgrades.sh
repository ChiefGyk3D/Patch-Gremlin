#!/bin/bash
#
# Patch Gremlin - Setup Script
# Configures automatic security updates on Debian/RHEL with notifications.
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -euo pipefail

PATCH_GREMLIN_VERSION="2.0.1"

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
PROFILE="default"
STAGGER_MINUTES=""
STAGGER_INDEX=""

say()  { echo -e "$*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
die()  { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

# Resolve a system path under the staging prefix.
p() { printf '%s%s' "$PG_ROOT" "$1"; }

# Write a file, creating parents, with an explicit mode.
write_file() {
    local path mode tmp
    path="$(p "$1")"; mode="$2"
    mkdir -p "$(dirname "$path")"
    # Populate a private sibling, set the final mode, then rename it over the
    # destination. Readers see either the complete old file or the complete
    # new file, never a truncated systemd or APT configuration.
    tmp="$(mktemp "${path}.tmp.XXXXXX")"
    chmod 600 "$tmp"
    if ! cat > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp"
    mv -f -- "$tmp" "$path"
}

# Quote a value for secrets.conf: wrap in double quotes, escaping only \ and ".
# update-notifier.sh parses (never sources) the file and undoes exactly this.
secret_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# Refuse secrets containing control characters (a newline would start a new
# line in the file).
reject_control_chars() {
    local name="$1" value="$2"
    if [[ "$value" =~ [[:cntrl:]] ]]; then
        die "$name contains a control character; refusing to write it"
    fi
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
      --profile NAME      Installation profile: default or proxmox
      --stagger-minutes N Space timer slots by N minutes (minimum: 60)
      --stagger-index I   Zero-based slot index; requires --stagger-minutes
  -h, --help              Show this help and exit
  -V, --version           Show the version and exit

Configuration environment variables (all optional in interactive mode):
  UPDATE_TYPE=security|all           What to install automatically
  UPDATE_SCHEDULE=daily|weekly       How often
  UPDATE_DAY=Sun..Sat                Day, when weekly (default: Sat)
  UPDATE_TIME=HH:MM                  24-hour local time (default: 02:00)
  SYSTEM_TIMEZONE=Area/City          Set the system timezone
  VERBOSE_LOGGING=true|false         unattended-upgrades debug output
  AUTO_REBOOT=true|false             Reboot when an update requires it (default: false)
  REBOOT_WITH_USERS=true|false       Reboot even with users logged in
                                     (default: false)
  ENABLE_HEARTBEAT=true|false        Also send a scheduled report even when
                                     no upgrade ran (default: false)
  ENABLE_PROMETHEUS=true|false       Install and enable textfile timer (default: false)
  PROMETHEUS_TEXTFILE_DIR=PATH       node_exporter textfile directory
  ENABLE_EVENTS=true|false           Append SIEM JSONL events (default: false)
  EVENTS_FILE=PATH                   JSONL path (default: /var/log/patch-gremlin/events.jsonl)
  EVENTS_MAX_BYTES=BYTES             Rotate threshold (default: 1048576)
  SECRET_MODE=doppler|local          Where secrets live
  DOPPLER_TOKEN=dp.st....            Required for doppler mode

Local-mode secrets (used with SECRET_MODE=local):
  LOCAL_DISCORD_WEBHOOK, LOCAL_SLACK_WEBHOOK, LOCAL_TEAMS_WEBHOOK,
  LOCAL_MATRIX_WEBHOOK, LOCAL_MATRIX_HOMESERVER, LOCAL_MATRIX_USERNAME,
  LOCAL_MATRIX_PASSWORD, LOCAL_MATRIX_ACCESS_TOKEN, LOCAL_MATRIX_ROOM_ID,
  LOCAL_NTFY_URL, LOCAL_NTFY_TOPIC, LOCAL_NTFY_TOKEN,
  LOCAL_GOTIFY_URL, LOCAL_GOTIFY_TOKEN, LOCAL_WEBHOOK_URL
  LOCAL_HEALTHCHECK_PING_URL, LOCAL_PUSHOVER_TOKEN, LOCAL_PUSHOVER_USER

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

timer_randomized_delay() {
    if [[ -n "$STAGGER_MINUTES" ]]; then
        printf '0'
    else
        printf '30min'
    fi
}

scheduled_update_time() {
    if [[ -n "$STAGGER_MINUTES" ]]; then
        time_plus_minutes "$UPDATE_TIME" "$((STAGGER_MINUTES * STAGGER_INDEX))"
    else
        printf '%s' "$UPDATE_TIME"
    fi
}

# ---------------------------------------------------------------------------
# config.sh loading
#
# The old loader grepped out `export` lines, warned if it *saw* a command
# substitution, then sourced the file anyway - so `export X="$(cmd)"` still
# executed as root. This parses KEY=VALUE against an allowlist and never
# evaluates the file.
# ---------------------------------------------------------------------------
CONFIG_ALLOWLIST='^(DOPPLER_(DISCORD|TEAMS|SLACK|MATRIX|MATRIX_HOMESERVER|MATRIX_USERNAME|MATRIX_PASSWORD|MATRIX_ROOM_ID|MATRIX_TOKEN|NTFY_URL|NTFY_TOPIC|NTFY_TOKEN|GOTIFY_URL|GOTIFY_TOKEN|WEBHOOK|HEALTHCHECK|PUSHOVER_TOKEN|PUSHOVER_USER)_SECRET|ENABLE_PROMETHEUS|PROMETHEUS_TEXTFILE_DIR|ENABLE_EVENTS|EVENTS_FILE|EVENTS_MAX_BYTES)$'

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

    # PATCH_GREMLIN_OS_TYPE forces the family, so the suite can exercise the
    # Debian and RHEL branches on whatever host it happens to run on. Without
    # it the tests only checked whichever family the CI image belonged to, and
    # every apt-path assertion failed on Fedora and Rocky.
    if [[ -n "${PATCH_GREMLIN_OS_TYPE:-}" ]]; then
        case "$PATCH_GREMLIN_OS_TYPE" in
            debian|rhel) OS_TYPE="$PATCH_GREMLIN_OS_TYPE" ;;
            *) die "PATCH_GREMLIN_OS_TYPE must be 'debian' or 'rhel' (got '$PATCH_GREMLIN_OS_TYPE')" ;;
        esac
    elif [[ "$OS_ID" =~ ^(debian|ubuntu|raspbian)$ ]] || [[ "$OS_LIKE" =~ debian ]]; then
        OS_TYPE="debian"
    elif [[ "$OS_ID" =~ ^(rhel|centos|rocky|almalinux|fedora|amzn)$ ]] || [[ "$OS_LIKE" =~ (rhel|fedora) ]]; then
        OS_TYPE="rhel"
    else
        die "Unsupported OS: $OS_ID (supported: Debian, Ubuntu, RHEL, Rocky, AlmaLinux, Amazon Linux, Fedora)"
    fi

    if [[ "$OS_TYPE" == "debian" ]]; then
        PACKAGE_MANAGER="apt-get"
    else
        # Amazon Linux 2 has no dnf; Fedora 41+ ships dnf5-automatic.
        if command -v dnf &>/dev/null; then
            PACKAGE_MANAGER="dnf"
        elif command -v yum &>/dev/null; then
            PACKAGE_MANAGER="yum"
        else
            PACKAGE_MANAGER="dnf"
        fi
    fi
}

# Fedora 41+ ships the dnf5 plugin. The PACKAGE is dnf5-plugin-automatic -
# there is no package called "dnf5-automatic", which is what this used to look
# for, so the check never matched and the installer always fell through to
# dnf-automatic. The plugin installs dnf5-automatic.service/.timer and reads
# the same /etc/dnf/automatic.conf.
automatic_package_name() {
    if [[ "$PACKAGE_MANAGER" == "yum" ]]; then
        echo "yum-cron"
        return 0
    fi
    local c
    for c in dnf5-plugin-automatic dnf5-automatic dnf-automatic; do
        if "$PACKAGE_MANAGER" list --available "$c" &>/dev/null; then
            echo "$c"
            return 0
        fi
    done
    echo "dnf-automatic"
}

# Package name -> systemd unit base. They differ: dnf5-plugin-automatic ships
# units called dnf5-automatic.*.
automatic_unit_for_package() {
    case "$1" in
        yum-cron)                          echo "yum-cron" ;;
        dnf5-plugin-automatic|dnf5-automatic) echo "dnf5-automatic" ;;
        *)                                 echo "dnf-automatic" ;;
    esac
}

# The systemd units are named after the PACKAGE: dnf5-automatic ships
# dnf5-automatic.service and dnf5-automatic.timer, not dnf-automatic.*.
# Hardcoding dnf-automatic meant that on Fedora 41+ - where dnf5-automatic is
# what actually gets installed - the ExecStartPost drop-in and the schedule
# override were written for units that do not exist, and
# `enable --now dnf-automatic.timer` failed. Automatic updates ran on the
# distro default schedule and no notification was ever sent.
AUTOMATIC_PACKAGE=""
AUTOMATIC_UNIT=""

resolve_automatic_units() {
    [[ -n "$AUTOMATIC_PACKAGE" ]] || AUTOMATIC_PACKAGE="$(automatic_package_name)"

    if [[ -n "${PATCH_GREMLIN_AUTOMATIC_UNIT:-}" ]]; then
        AUTOMATIC_UNIT="$PATCH_GREMLIN_AUTOMATIC_UNIT"
        return 0
    fi

    local preferred candidates=()
    preferred="$(automatic_unit_for_package "$AUTOMATIC_PACKAGE")"
    case "$preferred" in
        yum-cron)       candidates=(yum-cron) ;;
        dnf5-automatic) candidates=(dnf5-automatic dnf-automatic) ;;
        *)              candidates=(dnf-automatic dnf5-automatic) ;;
    esac

    # On a live system prefer whichever unit is genuinely present, so a
    # mis-detected package name cannot strand the drop-in on a phantom unit.
    if [[ -z "$PG_ROOT" ]] && command -v systemctl &>/dev/null; then
        local c
        for c in "${candidates[@]}"; do
            if systemctl cat "${c}.service" &>/dev/null; then
                AUTOMATIC_UNIT="$c"
                return 0
            fi
        done
    fi
    AUTOMATIC_UNIT="${candidates[0]}"
}

# yum-cron has no systemd timer - it is driven by /etc/cron.daily - so the
# schedule override and `enable --now` only apply where a timer exists.
automatic_has_timer() {
    [[ "$AUTOMATIC_UNIT" != "yum-cron" ]]
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

verify_proxmox_apt_policy() {
    local config_dir dump origins allowed allowed_origins bootstrap
    config_dir="$(p /etc/apt/apt.conf.d)"

    command -v apt-config >/dev/null 2>&1 || die "apt-config is required to verify the Proxmox policy"
    mkdir -p "$(p /var/lib/patch-gremlin)"
    bootstrap="$(mktemp "$(p /var/lib/patch-gremlin)/apt-config.XXXXXX")"
    printf 'Dir::Etc::parts "%s";\n' "$config_dir" > "$bootstrap"
    if ! dump="$(APT_CONFIG="$bootstrap" apt-config dump)"; then
        rm -f -- "$bootstrap"
        die "apt-config could not load the effective Proxmox policy"
    fi
    rm -f -- "$bootstrap"
    allowed="$(printf '%s\n' "$dump" | grep -E '^Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)' || true)"
    say "Effective Proxmox unattended-upgrades policy:"
    printf '%s\n' "$allowed"

    allowed_origins="$(printf '%s\n' "$allowed" | grep -E '^Unattended-Upgrade::Allowed-Origins::' || true)"
    [[ -z "$allowed_origins" ]] ||
        die "effective unattended-upgrades Allowed-Origins is not empty"
    origins="$(printf '%s\n' "$allowed" | sed -n 's/^Unattended-Upgrade::Origins-Pattern::[^ ]* "\(.*\)";$/\1/p')"
    [[ "$origins" == $'origin=Debian,codename=${distro_codename}-security,label=Debian-Security\norigin=Debian,codename=${distro_codename}-security' ]] ||
        die "effective unattended-upgrades origins are not limited to Debian security"
    printf '%s\n' "$dump" | grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' ||
        die "effective unattended-upgrades policy permits automatic reboot"
    printf '%s\n' "$dump" | grep -Fxq 'APT::Get::AllowUnauthenticated "false";' ||
        die "effective APT policy permits unauthenticated packages"
}

install_proxmox_controls() {
    rm -f -- "$(p /etc/apt/apt.conf.d/52patch-gremlin-proxmox)"
    write_file /etc/needrestart/conf.d/99zz-patch-gremlin-proxmox.conf 644 <<'EOF'
# Managed by Patch Gremlin. List affected services but never restart them.
$nrconf{restart} = 'l';
$nrconf{override_rc}{qr(^(?:corosync|pve-cluster|pveproxy|pvedaemon|pvestatd)(?:\.service)?$)} = 0;
EOF

    write_file /usr/local/libexec/patch-gremlin-proxmox-lock 755 <<'EOF'
#!/bin/bash
set -euo pipefail

pve_root="${PATCH_GREMLIN_PVE_ROOT:-/etc/pve}"
run_root="${PATCH_GREMLIN_RUN_ROOT:-/run/patch-gremlin}"
lock_parent="$pve_root/priv"
lock_dir="$lock_parent/patch-gremlin-upgrade.lock"
marker="$run_root/patch-gremlin-proxmox-lock.marker"
# Automatic upgrades are expected to finish within hours. Keep this at 24
# hours so a slow upgrade is not mistaken for a crashed owner.
stale_after=86400

log_message() {
    printf '%s\n' "$*"
    command -v logger >/dev/null 2>&1 && logger -t patch-gremlin -- "$*" 2>/dev/null || true
}

case "${1:-}" in
    acquire)
        if [[ ! -f "$pve_root/corosync.conf" ]]; then
            log_message "Proxmox node is not clustered; continuing without the cluster upgrade lock"
            exit 0
        fi
        if [[ ! -d "$lock_parent" ]]; then
            log_message "Proxmox cluster lock path is absent; continuing without the cluster upgrade lock"
            exit 0
        fi
        if mkdir "$lock_dir" 2>/dev/null; then
            node="$(hostname)"
            if [[ -r /proc/sys/kernel/random/uuid ]]; then
                invocation_id="$(cat /proc/sys/kernel/random/uuid)"
            else
                invocation_id="$(date +%s).$$.$RANDOM"
            fi
            owner="$node:$invocation_id"
            printf '%s\n' "$owner" > "$lock_dir/owner"
            date +%s > "$lock_dir/created"
            mkdir -p "$run_root"
            printf '%s\n' "$owner" > "$marker"
            log_message "Acquired the Proxmox cluster upgrade lock"
            exit 0
        fi
        now="$(date +%s)"
        created="$(cat "$lock_dir/created" 2>/dev/null || printf '0')"
        owner="$(cat "$lock_dir/owner" 2>/dev/null || true)"
        [[ "$created" =~ ^[0-9]+$ ]] || created=0
        if (( now - created > stale_after )); then
            previous_owner="${owner:-unknown}"
            rm -f -- "$lock_dir/created"
            rm -f -- "$lock_dir/owner"
            rmdir -- "$lock_dir" 2>/dev/null || true
            if mkdir "$lock_dir" 2>/dev/null; then
                node="$(hostname)"
                if [[ -r /proc/sys/kernel/random/uuid ]]; then
                    invocation_id="$(cat /proc/sys/kernel/random/uuid)"
                else
                    invocation_id="$(date +%s).$$.$RANDOM"
                fi
                owner="$node:$invocation_id"
                printf '%s\n' "$owner" > "$lock_dir/owner"
                printf '%s\n' "$now" > "$lock_dir/created"
                mkdir -p "$run_root"
                printf '%s\n' "$owner" > "$marker"
                log_message "Replaced a stale Proxmox cluster upgrade lock; previous owner $previous_owner; new owner $owner"
                exit 0
            fi
        fi
        log_message "Skipping automatic updates because another cluster node holds the upgrade lock"
        exit 1
        ;;
    release)
        [[ -f "$lock_dir/owner" ]] || exit 0
        lock_owner="$(cat "$lock_dir/owner")"
        node="$(hostname)"
        [[ -n "$lock_owner" && "$lock_owner" == "$node:"* ]] || exit 0
        rm -f -- "$lock_dir/created"
        rm -f -- "$lock_dir/owner"
        rmdir -- "$lock_dir" 2>/dev/null || true
        rm -f -- "$marker"
        log_message "Released the Proxmox cluster upgrade lock"
        ;;
    *)
        printf 'usage: %s acquire|release\n' "$0" >&2
        exit 2
        ;;
esac
EOF
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

    if [[ "$PROFILE" == "proxmox" ]]; then
        local reboot_time
        reboot_time="$(time_plus_minutes "$UPDATE_TIME" 60)"
        write_file /etc/apt/apt.conf.d/99zz-patch-gremlin-proxmox 644 <<EOF
// Managed by Patch Gremlin v${PATCH_GREMLIN_VERSION}.
// Proxmox packages are intentionally excluded and remain manually updated.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=\${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "${reboot_time}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
APT::Get::AllowUnauthenticated "false";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
Unattended-Upgrade::Verbose "${VERBOSE_LOGGING}";
EOF
        install_proxmox_controls
        verify_proxmox_apt_policy
    else
        backup_file /etc/apt/apt.conf.d/50unattended-upgrades

    local origins
    # shellcheck disable=SC2016 # ${distro_codename} is apt's variable, kept literal
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
    fi

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
RandomizedDelaySec=$(timer_randomized_delay)
$([[ "$PROFILE" == "proxmox" ]] && printf 'Persistent=false')
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
    # Resolve units only now: with the package installed, the systemctl probe
    # inside resolve_automatic_units can see which unit genuinely exists
    # rather than guessing from the package name alone.
    AUTOMATIC_PACKAGE="$pkg"
    resolve_automatic_units

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

    if automatic_has_timer; then
        write_file "/etc/systemd/system/${AUTOMATIC_UNIT}.timer.d/patch-gremlin.conf" 644 <<EOF
# Managed by Patch Gremlin
[Timer]
OnCalendar=
OnCalendar=$(oncalendar_expression)
RandomizedDelaySec=$(timer_randomized_delay)
EOF
        run_systemctl daemon-reload
        run_systemctl enable --now "${AUTOMATIC_UNIT}.timer"
    else
        run_systemctl daemon-reload
        run_systemctl enable "${AUTOMATIC_UNIT}.service"
        warn "${AUTOMATIC_PACKAGE} has no systemd timer; the schedule is whatever /etc/cron.daily uses"
    fi
    ok "Configured ${pkg} (${UPDATE_TYPE}, ${UPDATE_SCHEDULE} at ${UPDATE_TIME})"
}

oncalendar_expression() {
    local scheduled_time
    scheduled_time="$(scheduled_update_time)"
    if [[ "$UPDATE_SCHEDULE" == "weekly" ]]; then
        printf '%s *-*-* %s:00' "$UPDATE_DAY" "$scheduled_time"
    else
        printf '*-*-* %s:00' "$scheduled_time"
    fi
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
install_secrets() {
    mkdir -p "$(p /etc/update-notifier)"
    chmod 755 "$(p /etc/update-notifier)"

    if [[ "$SECRET_MODE" == "local" ]]; then
        # The file is PARSED by update-notifier.sh (KEY="VALUE", values taken
        # literally), never sourced. Values are quoted with only \ and "
        # escaped; control characters are rejected.
        local -a pairs=(
            DISCORD_WEBHOOK:LOCAL_DISCORD_WEBHOOK
            SLACK_WEBHOOK:LOCAL_SLACK_WEBHOOK
            TEAMS_WEBHOOK:LOCAL_TEAMS_WEBHOOK
            MATRIX_WEBHOOK:LOCAL_MATRIX_WEBHOOK
            MATRIX_HOMESERVER:LOCAL_MATRIX_HOMESERVER
            MATRIX_USERNAME:LOCAL_MATRIX_USERNAME
            MATRIX_PASSWORD:LOCAL_MATRIX_PASSWORD
            MATRIX_ACCESS_TOKEN:LOCAL_MATRIX_ACCESS_TOKEN
            MATRIX_ROOM_ID:LOCAL_MATRIX_ROOM_ID
            NTFY_URL:LOCAL_NTFY_URL
            NTFY_TOPIC:LOCAL_NTFY_TOPIC
            NTFY_TOKEN:LOCAL_NTFY_TOKEN
            GOTIFY_URL:LOCAL_GOTIFY_URL
            GOTIFY_TOKEN:LOCAL_GOTIFY_TOKEN
            GENERIC_WEBHOOK_URL:LOCAL_WEBHOOK_URL
            HEALTHCHECK_PING_URL:LOCAL_HEALTHCHECK_PING_URL
            PUSHOVER_TOKEN:LOCAL_PUSHOVER_TOKEN
            PUSHOVER_USER:LOCAL_PUSHOVER_USER
            PUSHOVER_PRIORITY:LOCAL_PUSHOVER_PRIORITY
            PUSHOVER_RETRY:LOCAL_PUSHOVER_RETRY
            PUSHOVER_EXPIRE:LOCAL_PUSHOVER_EXPIRE
        )
        local pair out src val
        out="# Patch Gremlin local secrets. Mode 600, root-owned."$'\n'
        out+='SECRET_MODE="local"'$'\n'
        for pair in "${pairs[@]}"; do
            src="${pair#*:}"
            val="${!src}"
            reject_control_chars "$src" "$val"
            out+="${pair%%:*}=$(secret_quote "$val")"$'\n'
        done
        printf '%s' "$out" | write_file /etc/update-notifier/secrets.conf 600
        ok "Wrote /etc/update-notifier/secrets.conf (mode 600)"
        # Nothing sensitive in the unit file itself.
        write_file /etc/update-notifier/env 600 <<EOF
SECRET_MODE=local
PATCH_GREMLIN_EVENTS_FILE=$([[ "$ENABLE_EVENTS" == true ]] && printf '%s' "$EVENTS_FILE")
PATCH_GREMLIN_EVENTS_MAX_BYTES=${EVENTS_MAX_BYTES}
EOF
    else
        # The Doppler token used to be embedded in the systemd unit AND in
        # /etc/apt/apt.conf.d/99patch-gremlin-notification, both mode 644 -
        # any local user could read it, and `systemctl show` exposed it too.
        # It now lives in one root-only EnvironmentFile.
        local v
        for v in DOPPLER_TOKEN DOPPLER_DISCORD_SECRET DOPPLER_TEAMS_SECRET DOPPLER_SLACK_SECRET \
                 DOPPLER_MATRIX_SECRET DOPPLER_MATRIX_HOMESERVER_SECRET DOPPLER_MATRIX_USERNAME_SECRET \
                 DOPPLER_MATRIX_PASSWORD_SECRET DOPPLER_MATRIX_ROOM_ID_SECRET DOPPLER_MATRIX_TOKEN_SECRET \
                 DOPPLER_NTFY_URL_SECRET DOPPLER_NTFY_TOPIC_SECRET DOPPLER_NTFY_TOKEN_SECRET \
                 DOPPLER_GOTIFY_URL_SECRET DOPPLER_GOTIFY_TOKEN_SECRET DOPPLER_WEBHOOK_SECRET \
                 DOPPLER_HEALTHCHECK_SECRET DOPPLER_PUSHOVER_TOKEN_SECRET DOPPLER_PUSHOVER_USER_SECRET; do
            reject_control_chars "$v" "${!v:-}"
        done
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
DOPPLER_MATRIX_TOKEN_SECRET=${DOPPLER_MATRIX_TOKEN_SECRET}
DOPPLER_NTFY_URL_SECRET=${DOPPLER_NTFY_URL_SECRET}
DOPPLER_NTFY_TOPIC_SECRET=${DOPPLER_NTFY_TOPIC_SECRET}
DOPPLER_NTFY_TOKEN_SECRET=${DOPPLER_NTFY_TOKEN_SECRET}
DOPPLER_GOTIFY_URL_SECRET=${DOPPLER_GOTIFY_URL_SECRET}
DOPPLER_GOTIFY_TOKEN_SECRET=${DOPPLER_GOTIFY_TOKEN_SECRET}
DOPPLER_WEBHOOK_SECRET=${DOPPLER_WEBHOOK_SECRET}
DOPPLER_HEALTHCHECK_SECRET=${DOPPLER_HEALTHCHECK_SECRET}
DOPPLER_PUSHOVER_TOKEN_SECRET=${DOPPLER_PUSHOVER_TOKEN_SECRET}
DOPPLER_PUSHOVER_USER_SECRET=${DOPPLER_PUSHOVER_USER_SECRET}
PATCH_GREMLIN_EVENTS_FILE=$([[ "$ENABLE_EVENTS" == true ]] && printf '%s' "$EVENTS_FILE")
PATCH_GREMLIN_EVENTS_MAX_BYTES=${EVENTS_MAX_BYTES}
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
    if [[ "${ENABLE_PROMETHEUS:-false}" == true && -f "$SCRIPT_DIR/monitoring/prometheus-textfile.sh" ]]; then
        install -m 755 "$SCRIPT_DIR/monitoring/prometheus-textfile.sh" "$(p /usr/local/bin/patch-gremlin-prometheus-textfile.sh)"
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
EnvironmentFile=-/etc/update-notifier/secrets.conf
ExecStart=/usr/local/bin/update-notifier.sh
User=root
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal
SyslogIdentifier=patch-gremlin

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
ReadWritePaths=/var/lib/patch-gremlin /run$([[ "$ENABLE_EVENTS" == true ]] && printf ' %s' "$(dirname "$EVENTS_FILE")")
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
        [[ -n "$AUTOMATIC_UNIT" ]] || resolve_automatic_units
        upgrade_unit="${AUTOMATIC_UNIT}.service"
    fi

    if [[ "$PROFILE" == "proxmox" ]]; then
        write_file "/etc/systemd/system/${upgrade_unit}.d/patch-gremlin.conf" 644 <<EOF
# Managed by Patch Gremlin. Serialize clustered upgrades and only list restarts.
[Service]
Environment=NEEDRESTART_MODE=l
ExecCondition=/usr/local/libexec/patch-gremlin-proxmox-lock acquire
ExecStopPost=/usr/local/libexec/patch-gremlin-proxmox-lock release
ExecStartPost=-/usr/bin/systemctl start --no-block update-notifier.service
EOF
    else
        write_file "/etc/systemd/system/${upgrade_unit}.d/patch-gremlin.conf" 644 <<EOF
# Managed by Patch Gremlin - notify once the upgrade run has finished.
[Service]
ExecStartPost=-/usr/bin/systemctl start --no-block update-notifier.service
EOF
    fi
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

    if [[ "${ENABLE_PROMETHEUS:-false}" == true ]]; then
        write_file /etc/systemd/system/patch-gremlin-prometheus.service 644 <<EOF
[Service]
Type=oneshot
Environment=PATCH_GREMLIN_TEXTFILE_DIR=${PROMETHEUS_TEXTFILE_DIR}
ExecStart=/usr/local/bin/patch-gremlin-prometheus-textfile.sh
User=root
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${PROMETHEUS_TEXTFILE_DIR}
EOF
        write_file /etc/systemd/system/patch-gremlin-prometheus.timer 644 <<'EOF'
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
        run_systemctl enable --now patch-gremlin-prometheus.timer
    fi
}

heartbeat_oncalendar() {
    # Two hours after the upgrade window so it never races the upgrade unit.
    local t
    t="$(time_plus_minutes "$(scheduled_update_time)" 120)"
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
    # Both dnf spellings: an install on Fedora 41+ lands under dnf5-automatic.
    local stale
    for stale in "$(p /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf)" \
                 "$(p /etc/systemd/system/dnf5-automatic.service.d/patch-gremlin.conf)"; do
        if [[ -f "$stale" ]] && grep -q 'DOPPLER_TOKEN' "$stale" 2>/dev/null; then
            rm -f "$stale"
            ok "Removed legacy dnf drop-in containing an inline Doppler token"
        fi
    done
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
    AUTO_REBOOT="${AUTO_REBOOT:-false}"
    REBOOT_WITH_USERS="${REBOOT_WITH_USERS:-false}"
    ENABLE_HEARTBEAT="${ENABLE_HEARTBEAT:-false}"
    ENABLE_PROMETHEUS="${ENABLE_PROMETHEUS:-false}"
    PROMETHEUS_TEXTFILE_DIR="${PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    ENABLE_EVENTS="${ENABLE_EVENTS:-false}"
    EVENTS_FILE="${EVENTS_FILE:-/var/log/patch-gremlin/events.jsonl}"
    EVENTS_MAX_BYTES="${EVENTS_MAX_BYTES:-1048576}"
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
        prompt REPLY_REBOOT "Reboot automatically when an update requires it? (y/N): " "n"
        [[ "$REPLY_REBOOT" =~ ^[Yy] ]] && AUTO_REBOOT="true" || AUTO_REBOOT="false"
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
    [[ "$ENABLE_PROMETHEUS" =~ ^(true|false)$ ]] || die "ENABLE_PROMETHEUS must be true or false"
    [[ "$ENABLE_EVENTS" =~ ^(true|false)$ ]] || die "ENABLE_EVENTS must be true or false"
    [[ "$EVENTS_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || die "EVENTS_MAX_BYTES must be a positive integer"

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
    LOCAL_HEALTHCHECK_PING_URL="${LOCAL_HEALTHCHECK_PING_URL:-}"
    LOCAL_PUSHOVER_TOKEN="${LOCAL_PUSHOVER_TOKEN:-}"
    LOCAL_PUSHOVER_USER="${LOCAL_PUSHOVER_USER:-}"
    LOCAL_PUSHOVER_PRIORITY="${LOCAL_PUSHOVER_PRIORITY:-0}"
    LOCAL_PUSHOVER_RETRY="${LOCAL_PUSHOVER_RETRY:-60}"
    LOCAL_PUSHOVER_EXPIRE="${LOCAL_PUSHOVER_EXPIRE:-3600}"
    [[ -z "$LOCAL_HEALTHCHECK_PING_URL" || "$LOCAL_HEALTHCHECK_PING_URL" =~ ^https:// ]] || die "LOCAL_HEALTHCHECK_PING_URL must use HTTPS"
    [[ -z "$LOCAL_PUSHOVER_TOKEN" && -z "$LOCAL_PUSHOVER_USER" ]] || [[ -n "$LOCAL_PUSHOVER_TOKEN" && -n "$LOCAL_PUSHOVER_USER" ]] || die "Pushover requires both LOCAL_PUSHOVER_TOKEN and LOCAL_PUSHOVER_USER"
    [[ "$LOCAL_PUSHOVER_PRIORITY" =~ ^(0|2)$ ]] || die "LOCAL_PUSHOVER_PRIORITY must be 0 or 2"

    [[ "$SECRET_MODE" == "local" ]] || return 0

    local configured="${LOCAL_DISCORD_WEBHOOK}${LOCAL_SLACK_WEBHOOK}${LOCAL_TEAMS_WEBHOOK}${LOCAL_MATRIX_WEBHOOK}${LOCAL_MATRIX_HOMESERVER}${LOCAL_NTFY_URL}${LOCAL_GOTIFY_URL}${LOCAL_WEBHOOK_URL}${LOCAL_HEALTHCHECK_PING_URL}${LOCAL_PUSHOVER_TOKEN}"
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

    configured="${LOCAL_DISCORD_WEBHOOK}${LOCAL_SLACK_WEBHOOK}${LOCAL_TEAMS_WEBHOOK}${LOCAL_MATRIX_WEBHOOK}${LOCAL_MATRIX_HOMESERVER}${LOCAL_NTFY_URL}${LOCAL_GOTIFY_URL}${LOCAL_WEBHOOK_URL}${LOCAL_HEALTHCHECK_PING_URL}${LOCAL_PUSHOVER_TOKEN}"
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
        if [[ "$mode" == "600" ]]; then
            ok "Secret environment file is mode 600"
        else
            warn "Secret environment file is mode $mode, expected 600"
        fi
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
            --profile)
                [[ $# -ge 2 ]] || { echo "--profile requires a value" >&2; exit 2; }
                PROFILE="$2"; shift ;;
            --stagger-minutes)
                [[ $# -ge 2 ]] || { echo "--stagger-minutes requires an integer" >&2; exit 2; }
                STAGGER_MINUTES="$2"; shift ;;
            --stagger-index)
                [[ $# -ge 2 ]] || { echo "--stagger-index requires an integer" >&2; exit 2; }
                STAGGER_INDEX="$2"; shift ;;
            -h|--help)            usage; exit 0 ;;
            -V|--version)         echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    [[ "$PROFILE" =~ ^(default|proxmox)$ ]] || {
        echo "--profile must be 'default' or 'proxmox'" >&2
        exit 2
    }
    if [[ -n "$STAGGER_MINUTES" || -n "$STAGGER_INDEX" ]]; then
        [[ "$STAGGER_MINUTES" =~ ^[0-9]+$ && "$STAGGER_INDEX" =~ ^[0-9]+$ ]] || {
            echo "--stagger-minutes and --stagger-index require unsigned integers and must be used together" >&2
            exit 2
        }
        (( STAGGER_MINUTES >= 60 )) || {
            echo "--stagger-minutes must be at least 60" >&2
            exit 2
        }
        (( STAGGER_MINUTES * STAGGER_INDEX < 1440 )) || {
            echo "stagger offset must be less than 1440 minutes" >&2
            exit 2
        }
    fi

    say "${BLUE}=== Patch Gremlin Setup v${PATCH_GREMLIN_VERSION} ===${NC}"

    if [[ -z "$PG_ROOT" && $EUID -ne 0 ]]; then
        die "This script must be run as root. Try: sudo -E $0"
    fi

    detect_os
    ok "Detected $OS_ID $OS_VERSION (type: $OS_TYPE, pkg: $PACKAGE_MANAGER)"
    if [[ "$PROFILE" == "proxmox" && "$OS_TYPE" != "debian" ]]; then
        die "The Proxmox profile requires a Debian-family system"
    fi

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
    # These seven were accepted by CONFIG_ALLOWLIST and advertised in
    # config.example.sh, but were never defaulted here nor written to the env
    # file - so a custom Doppler secret name for Matrix access tokens, ntfy,
    # Gotify or the generic webhook was silently discarded after setup had
    # reported it loaded.
    DOPPLER_MATRIX_TOKEN_SECRET="${DOPPLER_MATRIX_TOKEN_SECRET:-UPDATE_NOTIFIER_MATRIX_ACCESS_TOKEN}"
    DOPPLER_NTFY_URL_SECRET="${DOPPLER_NTFY_URL_SECRET:-UPDATE_NOTIFIER_NTFY_URL}"
    DOPPLER_NTFY_TOPIC_SECRET="${DOPPLER_NTFY_TOPIC_SECRET:-UPDATE_NOTIFIER_NTFY_TOPIC}"
    DOPPLER_NTFY_TOKEN_SECRET="${DOPPLER_NTFY_TOKEN_SECRET:-UPDATE_NOTIFIER_NTFY_TOKEN}"
    DOPPLER_GOTIFY_URL_SECRET="${DOPPLER_GOTIFY_URL_SECRET:-UPDATE_NOTIFIER_GOTIFY_URL}"
    DOPPLER_GOTIFY_TOKEN_SECRET="${DOPPLER_GOTIFY_TOKEN_SECRET:-UPDATE_NOTIFIER_GOTIFY_TOKEN}"
    DOPPLER_WEBHOOK_SECRET="${DOPPLER_WEBHOOK_SECRET:-UPDATE_NOTIFIER_WEBHOOK_URL}"
    DOPPLER_HEALTHCHECK_SECRET="${DOPPLER_HEALTHCHECK_SECRET:-UPDATE_NOTIFIER_HEALTHCHECK_PING_URL}"
    DOPPLER_PUSHOVER_TOKEN_SECRET="${DOPPLER_PUSHOVER_TOKEN_SECRET:-UPDATE_NOTIFIER_PUSHOVER_TOKEN}"
    DOPPLER_PUSHOVER_USER_SECRET="${DOPPLER_PUSHOVER_USER_SECRET:-UPDATE_NOTIFIER_PUSHOVER_USER}"

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
    if [[ "$PROFILE" == "proxmox" ]]; then
        UPDATE_TYPE=security
        AUTO_REBOOT=false
        REBOOT_WITH_USERS=false
    fi
    if [[ -n "$STAGGER_MINUTES" ]]; then
        local base_minutes stagger_offset
        base_minutes=$((10#${UPDATE_TIME%%:*} * 60 + 10#${UPDATE_TIME##*:}))
        stagger_offset=$((STAGGER_MINUTES * STAGGER_INDEX))
        (( base_minutes + stagger_offset < 1440 )) || {
            echo "staggered update time must remain within the same day" >&2
            exit 2
        }
    fi
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
