#!/bin/bash
# Timer-driven Prometheus textfile collector for Patch Gremlin.
set -uo pipefail

STATE_FILE="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}/state"
TEXTFILE_DIR="${PATCH_GREMLIN_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUTPUT_FILE="$TEXTFILE_DIR/patch_gremlin.prom"
STALE_SECONDS="${PATCH_GREMLIN_STATE_STALE_SECONDS:-129600}"
REBOOT_FILE="${PATCH_GREMLIN_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"

last_run_epoch=0 last_success_epoch=0 last_status=unknown held_back_count=0
read_state() {
    local file="$1" line key value mode owner expected
    [[ -r "$file" && ! -L "$file" ]] || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null)" || return 1
    expected=0; [[ $(id -u) -eq 0 ]] || expected="$(id -u)"
    (( (8#$mode & 022) == 0 )) || return 1
    [[ "$owner" == "$expected" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue; key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            last_run_epoch|last_success_epoch|held_back_count) [[ "$value" =~ ^[0-9]+$ ]] && printf -v "$key" %s "$value" ;;
            last_status) [[ "$value" =~ ^(updated|no-updates|updates-available|error|failed|none)$ ]] && last_status="$value" ;;
        esac
    done < "$file"
}

state_ok=false
if read_state "$STATE_FILE" && (( last_run_epoch > 0 )) && (( $(date +%s) - last_run_epoch <= STALE_SECONDS )); then state_ok=true; fi
if [[ "$state_ok" != true ]]; then last_status=unknown
elif [[ "$last_status" == no-updates || "$last_status" == updates-available ]]; then last_status=none
elif [[ "$last_status" == error ]]; then last_status=failed
fi
[[ "$last_status" == updated && "$last_success_epoch" -eq 0 ]] && last_success_epoch="$last_run_epoch"

simulation=""
if [[ -r "${PATCH_GREMLIN_APT_SIMULATION_FILE:-}" ]]; then simulation="$(<"$PATCH_GREMLIN_APT_SIMULATION_FILE")"
elif command -v apt-get >/dev/null 2>&1; then simulation="$(apt-get -s upgrade 2>/dev/null || true)"; fi
pending_all="$(printf '%s\n' "$simulation" | grep -c '^Inst ' || true)"
pending_security="$(printf '%s\n' "$simulation" | grep '^Inst ' | grep -ciE '(security\.debian\.org|[-/]security|Debian-Security)' || true)"
pending_proxmox="$(printf '%s\n' "$simulation" | grep '^Inst ' | grep -ciE '(proxmox|pve-(enterprise|no-subscription))' || true)"
held="$(printf '%s\n' "$simulation" | sed -n 's/^The following packages have been kept back:[[:space:]]*//p' | wc -w | tr -d ' ')"
[[ "$held" -gt 0 ]] || held="${held_back_count:-0}"
reboot=0; [[ -e "$REBOOT_FILE" ]] && reboot=1

mkdir -p "$TEXTFILE_DIR" || exit 1
tmp="$(mktemp "$TEXTFILE_DIR/.patch_gremlin.prom.tmp.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
{
    echo '# TYPE patch_gremlin_last_success_timestamp_seconds gauge'
    echo "patch_gremlin_last_success_timestamp_seconds $last_success_epoch"
    echo '# TYPE patch_gremlin_last_run_timestamp_seconds gauge'
    echo "patch_gremlin_last_run_timestamp_seconds $last_run_epoch"
    echo '# TYPE patch_gremlin_pending_packages gauge'
    printf 'patch_gremlin_pending_packages{kind="all"} %s\n' "$pending_all"
    printf 'patch_gremlin_pending_packages{kind="security"} %s\n' "$pending_security"
    printf 'patch_gremlin_pending_packages{kind="proxmox"} %s\n' "$pending_proxmox"
    echo "patch_gremlin_held_back_packages $held"
    echo "patch_gremlin_reboot_required $reboot"
    echo "node_reboot_required $reboot"
    for status in updated none failed unknown; do
        value=0; [[ "$last_status" == "$status" ]] && value=1
        printf 'patch_gremlin_last_run_status{status="%s"} %s\n' "$status" "$value"
    done
} > "$tmp"
chmod 644 "$tmp" && mv -f "$tmp" "$OUTPUT_FILE"
trap - EXIT
