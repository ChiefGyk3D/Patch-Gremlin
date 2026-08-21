#!/bin/bash
#
# Patch Gremlin - Configure verbose logging
# Enables or disables debug output from unattended-upgrades.

set -euo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PG_ROOT="${PATCH_GREMLIN_ROOT:-}"
p() { printf '%s%s' "$PG_ROOT" "$1"; }

UU_CONF="$(p /etc/apt/apt.conf.d/50unattended-upgrades)"
PERIODIC_CONF="$(p /etc/apt/apt.conf.d/20auto-upgrades)"
BACKUP_DIR="$(p /var/backups/patch-gremlin)"

usage() {
    cat <<EOF
Patch Gremlin verbosity control v${PATCH_GREMLIN_VERSION}

Usage: sudo ./configure-verbosity.sh [OPTIONS]

Options:
  -q, --quiet     Disable verbose logging (recommended)
  -v, --verbose   Enable debug logging
  -s, --show      Show the current setting and exit
  -h, --help      Show this help and exit
  -V, --version   Show the version and exit

With no option an interactive prompt is shown.
EOF
}

TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quiet)   TARGET="false" ;;
        -v|--verbose) TARGET="true" ;;
        -s|--show)    TARGET="show" ;;
        -h|--help)    usage; exit 0 ;;
        -V|--version) echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -z "$PG_ROOT" && $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}" >&2
    echo "Please run: sudo $0" >&2
    exit 1
fi

show_current() {
    echo "Current verbose logging status:"
    if [[ -f "$UU_CONF" ]]; then
        if grep -q 'Unattended-Upgrade::Verbose[[:space:]]*"true"' "$UU_CONF"; then
            echo -e "  50unattended-upgrades: ${GREEN}ENABLED${NC}"
        else
            echo -e "  50unattended-upgrades: ${BLUE}DISABLED${NC}"
        fi
    else
        echo -e "  ${RED}50unattended-upgrades not found${NC}"
    fi

    if [[ -f "$PERIODIC_CONF" ]]; then
        # grep -oP is a GNU/PCRE extension; use a portable expression instead.
        local val
        val="$(sed -n 's/.*APT::Periodic::Verbose[[:space:]]*"\([0-9]*\)".*/\1/p' "$PERIODIC_CONF" | tail -1)"
        val="${val:-0}"
        if [[ "$val" == "0" ]]; then
            echo -e "  20auto-upgrades: ${BLUE}DISABLED${NC} (Verbose: $val)"
        else
            echo -e "  20auto-upgrades: ${GREEN}ENABLED${NC} (Verbose: $val)"
        fi
    else
        echo -e "  ${RED}20auto-upgrades not found${NC}"
    fi
}

show_current

if [[ "$TARGET" == "show" ]]; then
    exit 0
fi

if [[ -z "$TARGET" ]]; then
    if [[ ! -t 0 ]]; then
        echo -e "${RED}Error: no TTY; pass --quiet or --verbose${NC}" >&2
        exit 2
    fi
    echo ""
    echo "  1) Disable verbose logging (quiet - recommended)"
    echo "  2) Enable verbose logging (debug)"
    echo "  3) Cancel"
    read -rp "Enter choice [1-3] (default: 1): " choice || choice=""
    case "$choice" in
        2) TARGET="true" ;;
        3) echo "Cancelled."; exit 0 ;;
        *) TARGET="false" ;;
    esac
fi

if [[ "$TARGET" == "true" ]]; then
    PERIODIC_VALUE=2
    ACTION="Enabling"
else
    PERIODIC_VALUE=0
    ACTION="Disabling"
fi

echo -e "${YELLOW}${ACTION} verbose logging...${NC}"

# Backups go outside apt.conf.d - APT warns about every unrecognised file
# extension there on each invocation.
backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp "$f" "$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
    echo -e "${GREEN}✓${NC} Backed up $(basename "$f")"
}

set_directive() {
    local file="$1" key="$2" value="$3" quoted="$4"
    [[ -f "$file" ]] || { echo -e "${RED}✗${NC} $file not found"; return 1; }
    # Drop any commented-out copies so the active setting is unambiguous.
    sed -i "\\|^[[:space:]]*//[[:space:]]*${key}|d" "$file"
    if grep -q "^[[:space:]]*${key}" "$file"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*\"[^\"]*\";|${key} ${quoted}${value}${quoted};|" "$file"
    else
        echo "${key} ${quoted}${value}${quoted};" >> "$file"
    fi
    echo -e "${GREEN}✓${NC} $(basename "$file"): ${key} = ${value}"
}

backup "$UU_CONF"
backup "$PERIODIC_CONF"
set_directive "$UU_CONF" "Unattended-Upgrade::Verbose" "$TARGET" '"' || true
set_directive "$PERIODIC_CONF" "APT::Periodic::Verbose" "$PERIODIC_VALUE" '"' || true

echo ""
echo -e "${GREEN}Done.${NC} Changes take effect on the next unattended-upgrades run."
