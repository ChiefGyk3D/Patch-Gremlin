#!/bin/bash
#
# Patch Gremlin Uninstaller
# Removes installed components, optionally the underlying update system too.

set -euo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PG_ROOT="${PATCH_GREMLIN_ROOT:-}"
NON_INTERACTIVE="${PATCH_GREMLIN_NON_INTERACTIVE:-false}"
REMOVE_UPDATE_SYSTEM="${REMOVE_UPDATE_SYSTEM:-false}"
KEEP_BACKUPS="${KEEP_BACKUPS:-true}"

p()   { printf '%s%s' "$PG_ROOT" "$1"; }
say() { echo -e "$*"; }
ok()  { echo -e "  ${GREEN}✓${NC} $*"; }
die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

run_systemctl() {
    if [[ -n "$PG_ROOT" ]]; then
        echo "systemctl $*" >> "$PG_ROOT/systemctl.log"
        return 0
    fi
    systemctl "$@" 2>/dev/null || true
}

usage() {
    cat <<EOF
Patch Gremlin uninstaller v${PATCH_GREMLIN_VERSION}

Usage: sudo ./uninstall.sh [OPTIONS]

Options:
  -a, --all               Also remove unattended-upgrades / dnf-automatic
  -y, --non-interactive   Do not prompt
      --purge-backups     Delete /var/backups/patch-gremlin as well
  -h, --help              Show this help and exit
  -V, --version           Show the version and exit

By default the update system is left in place and running, so the host keeps
receiving security updates after Patch Gremlin is removed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)             REMOVE_UPDATE_SYSTEM=true ;;
        -y|--non-interactive) NON_INTERACTIVE=true ;;
        --purge-backups)      KEEP_BACKUPS=false ;;
        -h|--help)            usage; exit 0 ;;
        -V|--version)         echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Every other privileged script checked this; the uninstaller did not, so it
# half-ran as an ordinary user with every rm failing silently.
if [[ -z "$PG_ROOT" && $EUID -ne 0 ]]; then
    die "This script must be run as root. Try: sudo $0"
fi

if [[ "$NON_INTERACTIVE" != "true" && -t 0 ]]; then
    say "${YELLOW}Patch Gremlin Uninstaller${NC}"
    say "  1) Remove Patch Gremlin only (keep automatic updates running)"
    say "  2) Remove everything including the update system"
    say "  3) Cancel"
    read -rp "Enter choice [1-3] (default: 1): " choice || choice=""
    case "$choice" in
        2) REMOVE_UPDATE_SYSTEM=true ;;
        3) echo "Cancelled."; exit 0 ;;
    esac
fi

say "${YELLOW}Stopping services...${NC}"
run_systemctl stop update-notifier.timer
run_systemctl disable update-notifier.timer
run_systemctl stop update-notifier.service

say "${YELLOW}Removing units, hooks and scripts...${NC}"
rm -f "$(p /etc/systemd/system/update-notifier.service)" \
      "$(p /etc/systemd/system/update-notifier.timer)"

# Drop-ins and hooks, current and legacy.
rm -f "$(p /etc/systemd/system/apt-daily-upgrade.service.d/patch-gremlin.conf)" \
      "$(p /etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf)" \
      "$(p /etc/apt/apt.conf.d/99patch-gremlin-notification)"
rm -rf "$(p /etc/systemd/system/apt-daily-upgrade.timer.d)" \
       "$(p /etc/systemd/system/dnf-automatic.timer.d)"
for d in /etc/systemd/system/apt-daily-upgrade.service.d \
         /etc/systemd/system/dnf-automatic.service.d \
         /etc/systemd/system/update-notifier.service.d; do
    rmdir "$(p "$d")" 2>/dev/null || true
done

rm -f "$(p /usr/local/bin/update-notifier.sh)" \
      "$(p /usr/local/bin/patch-gremlin-health-check.sh)" \
      "$(p /usr/local/bin/patch-gremlin-dnf-hook.sh)" \
      "$(p /usr/local/bin/nagios-check.sh)" \
      "$(p /usr/local/bin/prometheus-exporter.sh)"

say "${YELLOW}Removing configuration and state...${NC}"
rm -rf "$(p /etc/update-notifier)" "$(p /var/lib/patch-gremlin)"
rm -f "$(p /run/patch-gremlin.lock)"
ok "Removed secrets, configuration and state"

run_systemctl daemon-reload

if [[ "$REMOVE_UPDATE_SYSTEM" == "true" ]]; then
    say "${YELLOW}Removing the update system...${NC}"
    run_systemctl stop apt-daily-upgrade.timer
    run_systemctl disable apt-daily-upgrade.timer
    run_systemctl stop dnf-automatic.timer
    run_systemctl disable dnf-automatic.timer

    if [[ -z "$PG_ROOT" ]]; then
        if command -v apt-get &>/dev/null; then
            apt-get remove -y unattended-upgrades 2>/dev/null || true
        fi
        if command -v dnf &>/dev/null; then
            dnf remove -y dnf-automatic dnf5-automatic 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum remove -y yum-cron 2>/dev/null || true
        fi
    fi
    rm -f "$(p /etc/apt/apt.conf.d/50unattended-upgrades)" \
          "$(p /etc/apt/apt.conf.d/20auto-upgrades)" \
          "$(p /etc/dnf/automatic.conf)"
    say "${RED}Warning: automatic updates are now disabled on this host.${NC}"
else
    say "${YELLOW}Restoring pre-Patch-Gremlin configuration...${NC}"
    backup_dir="$(p /var/backups/patch-gremlin)"
    restore() {
        local name="$1" dest="$2" latest
        latest="$(find "$backup_dir" -maxdepth 1 -name "${name}.*" -type f 2>/dev/null | sort | tail -1)"
        if [[ -n "$latest" ]]; then
            cp "$latest" "$(p "$dest")"
            ok "Restored $dest"
        fi
    }
    if [[ -d "$backup_dir" ]]; then
        restore 50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
        restore 20auto-upgrades       /etc/apt/apt.conf.d/20auto-upgrades
        restore automatic.conf        /etc/dnf/automatic.conf
    fi
    run_systemctl enable apt-daily-upgrade.timer
    run_systemctl start apt-daily-upgrade.timer
    run_systemctl enable dnf-automatic.timer
    run_systemctl start dnf-automatic.timer
    ok "Automatic updates left enabled"
fi

if [[ "$KEEP_BACKUPS" != "true" ]]; then
    rm -rf "$(p /var/backups/patch-gremlin)"
    ok "Removed backups"
fi

# Only rewrite root's crontab if an entry of ours is actually present -
# piping an empty stream into `crontab -` would install a blank crontab.
if [[ -z "$PG_ROOT" ]] && command -v crontab &>/dev/null; then
    if crontab -l 2>/dev/null | grep -q 'prometheus-exporter.sh\|patch-gremlin'; then
        crontab -l 2>/dev/null | grep -v 'prometheus-exporter.sh\|patch-gremlin' | crontab -
        ok "Removed Patch Gremlin crontab entries"
    fi
fi

run_systemctl daemon-reload

say "\n${GREEN}✓ Patch Gremlin removed${NC}"
if [[ "$KEEP_BACKUPS" == "true" && -d "$(p /var/backups/patch-gremlin)" ]]; then
    say "Backups kept in /var/backups/patch-gremlin (remove with --purge-backups)"
fi
say "Doppler credentials, if any, remain in /root/.doppler/"
