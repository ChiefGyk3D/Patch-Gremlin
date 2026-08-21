#!/bin/bash
#
# Patch Gremlin - on-host deployment verification.
# Checks a real installation end to end and exits non-zero if anything failed.

set -uo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ASSUME_YES="${PATCH_GREMLIN_ASSUME_YES:-false}"
SKIP_LIVE="${PATCH_GREMLIN_SKIP_LIVE:-false}"

PASSED=0
FAILED=0
SKIPPED=0

usage() {
    cat <<EOF
Patch Gremlin deployment test v${PATCH_GREMLIN_VERSION}

Usage: sudo ./test-deployment.sh [OPTIONS]

Options:
  -y, --yes         Answer yes to the live notification test
  -s, --skip-live   Never send a live notification
  -h, --help        Show this help and exit
  -V, --version     Show the version and exit

Exits 0 only if every check passed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)       ASSUME_YES=true ;;
        -s|--skip-live) SKIP_LIVE=true ;;
        -h|--help)      usage; exit 0 ;;
        -V|--version)   echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Plain assignment, not ((PASSED++)) - post-increment returns the OLD value,
# so the first ((x++)) returns status 1 and kills the script under `set -e`.
pass() { PASSED=$((PASSED + 1)); echo -e "${GREEN}✓${NC} $*"; }
fail() { FAILED=$((FAILED + 1)); echo -e "${RED}✗${NC} $*"; }
skip() { SKIPPED=$((SKIPPED + 1)); echo -e "${YELLOW}·${NC} $* (skipped)"; }
head2() { echo ""; echo -e "${BLUE}═══ $* ═══${NC}"; }

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      Patch Gremlin Deployment Test v${PATCH_GREMLIN_VERSION}             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root: sudo bash $0${NC}" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
head2 "Environment"
# ---------------------------------------------------------------------------
if [[ -f /etc/debian_version ]]; then
    OS_TYPE=debian; UPDATE_TIMER=apt-daily-upgrade.timer; UPGRADE_UNIT=apt-daily-upgrade.service
elif [[ -f /etc/redhat-release ]] || [[ -f /etc/system-release ]]; then
    OS_TYPE=rhel;   UPDATE_TIMER=dnf-automatic.timer;     UPGRADE_UNIT=dnf-automatic.service
else
    echo -e "${RED}Unsupported OS${NC}" >&2
    exit 2
fi
pass "Detected OS type: $OS_TYPE"

# ---------------------------------------------------------------------------
head2 "Installation"
# ---------------------------------------------------------------------------
for f in /usr/local/bin/update-notifier.sh \
         /usr/local/bin/patch-gremlin-health-check.sh \
         /etc/systemd/system/update-notifier.service \
         "/etc/systemd/system/${UPGRADE_UNIT}.d/patch-gremlin.conf"; do
    if [[ -e "$f" ]]; then pass "Present: $f"; else fail "Missing: $f"; fi
done

if [[ -f /etc/apt/apt.conf.d/99patch-gremlin-notification ]]; then
    fail "Legacy APT Dpkg::Post-Invoke hook present (fires on every apt run)"
    echo "    Fix: sudo -E ./setup-unattended-upgrades.sh --update-only"
else
    pass "No legacy APT hook"
fi

# ---------------------------------------------------------------------------
head2 "Secrets"
# ---------------------------------------------------------------------------
if [[ -f /etc/update-notifier/secrets.conf ]]; then
    perms="$(stat -c '%a' /etc/update-notifier/secrets.conf)"
    if [[ "$perms" == "600" ]]; then
        pass "secrets.conf is mode 600"
    else
        fail "secrets.conf is mode $perms (expected 600)"
    fi
    endpoints=0
    for key in DISCORD_WEBHOOK SLACK_WEBHOOK TEAMS_WEBHOOK MATRIX_WEBHOOK \
               MATRIX_HOMESERVER NTFY_URL GOTIFY_URL GENERIC_WEBHOOK_URL; do
        if grep -qE "^${key}=\"?[^\"[:space:]]+\"?$" /etc/update-notifier/secrets.conf; then
            endpoints=$((endpoints + 1))
        fi
    done
    if [[ $endpoints -gt 0 ]]; then
        pass "$endpoints notification endpoint(s) configured"
    else
        fail "No notification endpoints configured"
    fi
elif [[ -f /etc/update-notifier/env ]]; then
    perms="$(stat -c '%a' /etc/update-notifier/env)"
    if [[ "$perms" == "600" ]]; then
        pass "env file is mode 600"
    else
        fail "env file is mode $perms (expected 600)"
    fi
else
    fail "No secret storage found in /etc/update-notifier"
fi

# The token must never be readable by ordinary users.
leaked=0
while IFS= read -r f; do
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo 000)"
    if [[ "${mode: -1}" =~ [4567] ]] && grep -q 'dp\.st\.' "$f" 2>/dev/null; then
        fail "Doppler token readable in world-readable $f (mode $mode)"
        leaked=1
    fi
done < <(find /etc/systemd/system /etc/apt/apt.conf.d -type f 2>/dev/null)
[[ $leaked -eq 0 ]] && pass "No Doppler token in any world-readable file"

# ---------------------------------------------------------------------------
head2 "Systemd"
# ---------------------------------------------------------------------------
if systemctl is-enabled "$UPDATE_TIMER" &>/dev/null; then
    pass "$UPDATE_TIMER is enabled"
else
    fail "$UPDATE_TIMER is not enabled - automatic updates will not run"
fi

if systemctl cat "$UPGRADE_UNIT" 2>/dev/null | grep -q 'update-notifier.sh'; then
    pass "Notifier is wired to $UPGRADE_UNIT"
else
    fail "Notifier is not wired to $UPGRADE_UNIT"
fi

echo ""
systemctl list-timers "$UPDATE_TIMER" update-notifier.timer --no-pager 2>/dev/null || true

# ---------------------------------------------------------------------------
head2 "Notifier dry run"
# ---------------------------------------------------------------------------
if [[ -x /usr/local/bin/update-notifier.sh ]]; then
    if out="$(PATCH_GREMLIN_DRY_RUN=true /usr/local/bin/update-notifier.sh 2>&1)"; then
        pass "Dry run succeeded"
    else
        fail "Dry run failed: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
else
    fail "Notifier not executable"
fi

# ---------------------------------------------------------------------------
head2 "Pending updates"
# ---------------------------------------------------------------------------
if [[ "$OS_TYPE" == "debian" ]]; then
    apt-get update -qq 2>/dev/null || echo -e "${YELLOW}  (apt-get update failed; counts may be stale)${NC}"
    # grep -c writes "0" AND exits 1 on no match, so `|| echo 0` would emit
    # "0" twice and break the numeric comparison below.
    upgradable="$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true)"
    upgradable="${upgradable//[^0-9]/}"
    echo "  Upgradable packages: ${upgradable:-0}"
else
    # dnf check-update exits 100 when updates exist - not an error.
    out="$(dnf check-update -q 2>/dev/null)"; rc=$?
    if [[ $rc -eq 0 || $rc -eq 100 ]]; then
        upgradable="$(printf '%s\n' "$out" | grep -cvE '^(Last metadata|Obsoleting|Security:|$)' || true)"
        upgradable="${upgradable//[^0-9]/}"
        echo "  Upgradable packages: ${upgradable:-0}"
    else
        echo -e "${YELLOW}  dnf check-update failed with status $rc${NC}"
    fi
fi
pass "Update check completed"

# ---------------------------------------------------------------------------
head2 "Live notification"
# ---------------------------------------------------------------------------
if [[ "$SKIP_LIVE" == "true" ]]; then
    skip "Live notification test"
else
    do_live="$ASSUME_YES"
    if [[ "$do_live" != "true" ]]; then
        if [[ -t 0 ]]; then
            read -rp "Send a real test notification now? (y/N): " reply || reply=""
            [[ "$reply" =~ ^[Yy] ]] && do_live=true
        fi
    fi
    if [[ "$do_live" == "true" ]]; then
        systemctl start update-notifier.service 2>&1 || true
        # Type=oneshot: `systemctl start` returns once it has finished.
        code="$(systemctl show update-notifier.service --property=ExecMainStatus --value)"
        if [[ "$code" == "0" ]]; then
            pass "Live notification sent - check your channels"
        else
            fail "Live notification failed (exit $code); see journalctl -u update-notifier.service"
        fi
    else
        skip "Live notification test"
    fi
fi

# NB: this script no longer installs and removes a throwaway package to
# exercise the hook. It ran `apt-get autoremove -y` afterwards, which can pull
# far more than the test package on a production host.

# ---------------------------------------------------------------------------
head2 "Summary"
# ---------------------------------------------------------------------------
echo -e "  ${GREEN}Passed:${NC}  $PASSED"
echo -e "  ${RED}Failed:${NC}  $FAILED"
echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
echo ""
if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}Deployment test FAILED${NC}"
    echo "Run sudo ./diagnose-config.sh for a detailed report."
    exit 1
fi
echo -e "${GREEN}Deployment test PASSED${NC}"
exit 0
