#!/bin/bash
# Timer-driven Prometheus textfile collector for Patch Gremlin.
set -uo pipefail

STATE_FILE="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}/state"
TEXTFILE_DIR="${PATCH_GREMLIN_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUTPUT_FILE="$TEXTFILE_DIR/patch_gremlin.prom"
STALE_SECONDS="${PATCH_GREMLIN_STATE_STALE_SECONDS:-129600}"
REBOOT_FILE="${PATCH_GREMLIN_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
REBOOT_PKGS_FILE="${PATCH_GREMLIN_REBOOT_REQUIRED_PKGS_FILE:-/var/run/reboot-required.pkgs}"

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

declare -A pending_candidates=() candidate_kind=()
while IFS= read -r package; do
    [[ -n "$package" ]] && pending_candidates["$package"]=1
done < <(printf '%s\n' "$simulation" | awk '
    /^Inst / && $2 ~ /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$/ { print $2 }
')
pending_all="${#pending_candidates[@]}"

policy=""
if [[ -r "${PATCH_GREMLIN_APT_POLICY_FILE:-}" ]]; then
    policy="$(<"$PATCH_GREMLIN_APT_POLICY_FILE")"
elif (( pending_all > 0 )) && command -v apt-cache >/dev/null 2>&1; then
    mapfile -t policy_packages < <(printf '%s\n' "${!pending_candidates[@]}" | LC_ALL=C sort)
    policy="$(apt-cache policy "${policy_packages[@]}" 2>/dev/null || true)"
fi

# Accept only the stock apt-cache policy shape. Classification uses the
# candidate version's exact repository row and exact repository host; package
# text is data throughout and is never evaluated as shell input.
while IFS=$'\t' read -r package kind; do
    [[ -n "$package" && ${pending_candidates[$package]+present} ]] || continue
    candidate_kind["$package"]="$kind"
done < <(printf '%s\n' "$policy" | awk '
    function reset() { pkg=""; candidate=""; matched=0 }
    /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?:$/ {
        reset(); pkg=substr($0, 1, length($0)-1); next
    }
    pkg != "" && $1 == "Candidate:" && NF == 2 { candidate=$2; next }
    pkg != "" && candidate != "" && NF == 2 && $1 == candidate && $2 ~ /^[0-9]+$/ {
        matched=1; next
    }
    matched && NF == 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^https?:\/\/[^[:space:]]+$/ &&
        $3 ~ /^[a-z0-9.+_-]+\/[a-z0-9.+_-]+$/ && $4 ~ /^[a-z0-9]+$/ && $5 == "Packages" {
        kind="other"
        if ($2 ~ /^https?:\/\/(download|enterprise)\.proxmox\.com\//) kind="proxmox"
        else if ($2 ~ /^https?:\/\/security\.debian\.org\// && $3 ~ /-security\//) kind="security"
        print pkg "\t" kind
        matched=0
    }
')

pending_security=0 pending_proxmox=0
for package in "${!pending_candidates[@]}"; do
    [[ "${candidate_kind[$package]:-}" == security ]] && pending_security=$((pending_security + 1))
    [[ "${candidate_kind[$package]:-}" == proxmox ]] && pending_proxmox=$((pending_proxmox + 1))
done

held="$(printf '%s\n' "$simulation" | awk '
    /^The following packages have been kept back:/ {
        in_list=1
        sub(/^The following packages have been kept back:[[:space:]]*/, "")
        for (i=1; i<=NF; i++) if ($i ~ /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$/) count++
        next
    }
    in_list && /^  / {
        for (i=1; i<=NF; i++) if ($i ~ /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$/) count++
        next
    }
    in_list { in_list=0 }
    END { print count + 0 }
')"
[[ "$held" -gt 0 ]] || held="${held_back_count:-0}"
reboot=0; [[ -e "$REBOOT_FILE" ]] && reboot=1
reboot_packages=0
if [[ -r "$REBOOT_PKGS_FILE" ]]; then
    reboot_packages="$(awk 'NF { count++ } END { print count + 0 }' "$REBOOT_PKGS_FILE")"
fi

validate_textfile_dir() {
    local mode owner current_uid
    [[ "$TEXTFILE_DIR" == /* && -d "$TEXTFILE_DIR" && ! -L "$TEXTFILE_DIR" ]] &&
        [[ "$(realpath -e -- "$TEXTFILE_DIR" 2>/dev/null)" == "$TEXTFILE_DIR" ]] || {
        echo "Refusing unsafe Prometheus textfile directory" >&2
        return 1
    }
    mode="$(stat -c '%a' -- "$TEXTFILE_DIR" 2>/dev/null)" || return 1
    owner="$(stat -c '%u' -- "$TEXTFILE_DIR" 2>/dev/null)" || return 1
    current_uid="$(id -u)" || return 1
    [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || {
        echo "Refusing Prometheus textfile directory with an unexpected owner" >&2
        return 1
    }
    (( (8#$mode & 8#1022) == 0 )) || {
        echo "Refusing writable or sticky Prometheus textfile directory" >&2
        return 1
    }
}

validate_textfile_dir || exit 1
[[ ! -L "$OUTPUT_FILE" ]] || { echo "Refusing symlinked Prometheus output file" >&2; exit 1; }
umask 022
tmp="$(mktemp "$TEXTFILE_DIR/.patch_gremlin.prom.tmp.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
exec 3>"$tmp" || exit 1
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
    echo "patch_gremlin_reboot_required_packages $reboot_packages"
    for status in updated none failed unknown; do
        value=0; [[ "$last_status" == "$status" ]] && value=1
        printf 'patch_gremlin_last_run_status{status="%s"} %s\n' "$status" "$value"
    done
} >&3
exec 3>&-
mv -f -- "$tmp" "$OUTPUT_FILE"
trap - EXIT
