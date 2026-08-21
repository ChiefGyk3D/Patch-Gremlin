#!/bin/bash
#
# Patch Gremlin - Multi-Platform Update Notifier
# Sends system update notifications to Discord, Slack, Teams, Matrix, ntfy and Gotify.
# Supports both Doppler and local file storage for secrets.
# https://github.com/ChiefGyk3D/Patch-Gremlin

set -euo pipefail

PATCH_GREMLIN_VERSION="2.0.0"

# ---------------------------------------------------------------------------
# Tunables (environment overridable)
# ---------------------------------------------------------------------------
MAX_LOG_LINES="${PATCH_GREMLIN_MAX_LOG_LINES:-50}"
RETRY_COUNT="${PATCH_GREMLIN_RETRY_COUNT:-3}"
RETRY_DELAY="${PATCH_GREMLIN_RETRY_DELAY:-2}"
CURL_TIMEOUT="${PATCH_GREMLIN_CURL_TIMEOUT:-30}"
DRY_RUN="${PATCH_GREMLIN_DRY_RUN:-false}"
MAX_PACKAGE_NAMES="${PATCH_GREMLIN_MAX_PACKAGE_NAMES:-20}"
# Send even when there is nothing to report? changes|always
NOTIFY_ON="${PATCH_GREMLIN_NOTIFY_ON:-always}"
BOT_NAME="${PATCH_GREMLIN_BOT_NAME:-Patch Gremlin}"

# Paths (overridable so the suite can run without touching the host)
SECRETS_FILE="${PATCH_GREMLIN_SECRETS_FILE:-/etc/update-notifier/secrets.conf}"
CONFIG_FILE="${PATCH_GREMLIN_CONFIG_FILE:-/etc/update-notifier/config.sh}"
ENV_FILE="${PATCH_GREMLIN_ENV_FILE:-/etc/update-notifier/env}"
STATE_DIR="${PATCH_GREMLIN_STATE_DIR:-/var/lib/patch-gremlin}"
LOCK_FILE="${PATCH_GREMLIN_LOCK_FILE:-/run/patch-gremlin.lock}"

# Discord embed colours
readonly COLOR_GREEN=5814783
readonly COLOR_ORANGE=16744272
readonly COLOR_BLUE=3447003
readonly COLOR_RED=15158332

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    logger -t "patch-gremlin" "$*" 2>/dev/null || true
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
    fi
}

usage() {
    cat <<EOF
Patch Gremlin notifier v${PATCH_GREMLIN_VERSION}

Usage: update-notifier.sh [OPTIONS]

Sends a system-update report to every configured notification platform.
Normally invoked by systemd after unattended-upgrades / dnf-automatic.

Options:
  -n, --dry-run    Build the notification but do not send it
  -h, --help       Show this help and exit
  -V, --version    Show the version and exit

Environment:
  PATCH_GREMLIN_DRY_RUN=true          Same as --dry-run
  PATCH_GREMLIN_NOTIFY_ON=changes     Only notify when something changed
  PATCH_GREMLIN_MAX_LOG_LINES=50      Log lines to inspect
  PATCH_GREMLIN_RETRY_COUNT=3         HTTP retries per platform
  PATCH_GREMLIN_RETRY_DELAY=2         Seconds between retries
  PATCH_GREMLIN_CURL_TIMEOUT=30       HTTP timeout in seconds
  PATCH_GREMLIN_BOT_NAME="Patch Gremlin"

Secrets are read from Doppler or ${SECRETS_FILE}.
EOF
}

# ---------------------------------------------------------------------------
# Cleanup: ONE trap, one list of files. Registering a second trap would
# silently discard the first, which used to leak the log snapshot every run.
# ---------------------------------------------------------------------------
CLEANUP_FILES=()
cleanup() {
    local f
    for f in "${CLEANUP_FILES[@]:-}"; do
        [[ -n "$f" ]] && rm -f "$f"
    done
    matrix_logout
}
register_temp() { CLEANUP_FILES+=("$1"); }
# Sets MAKE_TEMP_RESULT. Deliberately NOT usable as "$(make_temp)" - a command
# substitution runs in a subshell, so the cleanup registration would be lost
# and the file leaked.
MAKE_TEMP_RESULT=""
make_temp() {
    MAKE_TEMP_RESULT="$(mktemp)"
    register_temp "$MAKE_TEMP_RESULT"
}

# ---------------------------------------------------------------------------
# JSON escaping - one implementation, used for every interpolated value.
# Emits the *contents* of a JSON string (no surrounding quotes).
# ---------------------------------------------------------------------------
json_escape() {
    local raw="$1"
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$raw" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1], end="")'
    else
        # Pure-bash fallback: backslash, quote, then control characters.
        local s="$raw"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\t'/\\t}"
        s="${s//$'\r'/}"
        s="${s//$'\n'/\\n}"
        printf '%s' "$s" | tr -d '[:cntrl:]'
    fi
}

# ---------------------------------------------------------------------------
# OS / log-file detection
# ---------------------------------------------------------------------------
detect_os_type() {
    if [[ -n "${PATCH_GREMLIN_OS_TYPE:-}" ]]; then
        printf '%s' "$PATCH_GREMLIN_OS_TYPE"
        return 0
    fi
    if [[ -r /etc/os-release ]]; then
        local ID="" ID_LIKE=""
        # shellcheck source=/dev/null
        . /etc/os-release
        if [[ "${ID:-}" =~ ^(debian|ubuntu|raspbian)$ ]] || [[ "${ID_LIKE:-}" =~ debian ]]; then
            printf 'debian'; return 0
        fi
        if [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux|fedora|amzn)$ ]] || [[ "${ID_LIKE:-}" =~ (rhel|fedora) ]]; then
            printf 'rhel'; return 0
        fi
    fi
    # Last resort: infer from which log exists.
    if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
        printf 'debian'
    elif [[ -f /var/log/dnf.log ]] || [[ -f /var/log/yum.log ]]; then
        printf 'rhel'
    else
        printf 'debian'
    fi
}

detect_log_file() {
    local os_type="$1"
    if [[ -n "${PATCH_GREMLIN_LOG_FILE:-}" ]]; then
        printf '%s' "$PATCH_GREMLIN_LOG_FILE"
        return 0
    fi
    if [[ "$os_type" == "debian" ]]; then
        printf '/var/log/unattended-upgrades/unattended-upgrades.log'
    elif [[ -f /var/log/dnf.log ]]; then
        printf '/var/log/dnf.log'
    else
        printf '/var/log/yum.log'
    fi
}

# ---------------------------------------------------------------------------
# Log parsing
#
# Debian: unattended-upgrades writes the package list on the SAME line as the
# marker, e.g.
#     2025-08-20 06:17:18,123 INFO Packages that will be upgraded: libssl3 curl
# The previous implementation skipped that line and then bailed on the next
# line (which also contains "INFO"), so it always returned nothing - which in
# turn made the notifier report "No updates applied" on the very runs where
# updates HAD been applied.
# ---------------------------------------------------------------------------
parse_upgraded_packages() {
    local log_file="$1" os_type="$2"
    [[ -r "$log_file" ]] || return 0

    if [[ "$os_type" == "debian" ]]; then
        # Last occurrence wins so we describe the most recent run only.
        local line
        line="$(grep 'Packages that will be upgraded:' "$log_file" 2>/dev/null | tail -n 1 || true)"
        [[ -n "$line" ]] || return 0
        local names="${line#*Packages that will be upgraded:}"
        # Deliberate word splitting: normalises runs of whitespace into a
        # single-space list.
        # shellcheck disable=SC2206,SC2086
        local -a pkgs=($names)
        [[ ${#pkgs[@]} -gt 0 ]] || return 0
        printf '%s\n' "${pkgs[*]}"
        return 0
    fi

    # RHEL: keep only the newest transaction block, then turn each NVRA into
    # a bare package name (openssl-1:3.0.7-27.el9.x86_64 -> openssl).
    local block
    block="$(awk '/--- logging initialized ---/{buf=""; next} {buf=buf $0 "\n"} END{printf "%s", buf}' "$log_file" 2>/dev/null || true)"
    [[ -n "$block" ]] || block="$(cat "$log_file")"

    local out=() nvra name
    while read -r nvra; do
        [[ -n "$nvra" ]] || continue
        name="${nvra%.*}"      # strip .arch
        name="${name%-*}"      # strip -release
        name="${name%-*}"      # strip -version
        [[ -n "$name" ]] && out+=("$name")
    done < <(printf '%s\n' "$block" | grep -oE 'Upgraded: *[^ ]+' | sed 's/Upgraded: *//' || true)

    [[ ${#out[@]} -gt 0 ]] || return 0
    printf '%s\n' "${out[*]}"
}

# Packages held back by unattended-upgrades, if any.
parse_kept_back() {
    local log_file="$1"
    [[ -r "$log_file" ]] || return 0
    grep 'kept back' "$log_file" 2>/dev/null | tail -n 1 | sed 's/.*kept back:[[:space:]]*//' || true
}

parse_last_error() {
    local log_file="$1"
    [[ -r "$log_file" ]] || return 0
    grep -E '(ERROR|CRITICAL)' "$log_file" 2>/dev/null | tail -n 1 | sed 's/^[0-9:,. -]*\(ERROR\|CRITICAL\)[[:space:]]*//' || true
}

# ---------------------------------------------------------------------------
# Pending update counts
#
# dnf check-update exits 100 when updates ARE available. Combined with
# `set -e -o pipefail` that used to abort the whole notifier on RHEL - i.e. it
# only worked when there was nothing to report.
# ---------------------------------------------------------------------------
count_pending_updates() {
    local os_type="$1"
    PENDING_TOTAL=0
    PENDING_SECURITY=0
    PENDING_NAMES=""

    if [[ "$os_type" == "debian" ]]; then
        command -v apt >/dev/null 2>&1 || return 0
        local listing
        listing="$(apt list --upgradable 2>/dev/null | grep 'upgradable from' || true)"
        [[ -n "$listing" ]] || return 0
        PENDING_TOTAL="$(printf '%s\n' "$listing" | wc -l | tr -d '[:space:]')"
        PENDING_SECURITY="$(printf '%s\n' "$listing" | grep -c -- '-security' || true)"
        PENDING_SECURITY="${PENDING_SECURITY//[^0-9]/}"
        PENDING_NAMES="$(printf '%s\n' "$listing" | awk -F/ '{print $1}' \
            | head -n "$MAX_PACKAGE_NAMES" | paste -sd', ' - || true)"
        return 0
    fi

    command -v dnf >/dev/null 2>&1 || return 0
    local out rc
    set +e
    out="$(dnf check-update -q 2>/dev/null)"
    rc=$?
    set -e
    # 0 = nothing to do, 100 = updates available, anything else = real failure
    if [[ $rc -ne 0 && $rc -ne 100 ]]; then
        log "WARNING: dnf check-update failed with status $rc"
        return 0
    fi
    out="$(printf '%s\n' "$out" | grep -vE '^(Last metadata|Obsoleting|Security:|$)' || true)"
    [[ -n "$out" ]] || return 0
    PENDING_TOTAL="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
    PENDING_NAMES="$(printf '%s\n' "$out" | awk '{print $1}' | sed 's/\.[^.]*$//' \
        | head -n "$MAX_PACKAGE_NAMES" | paste -sd', ' - || true)"

    set +e
    local sec
    sec="$(dnf check-update --security -q 2>/dev/null | grep -cvE '^(Last metadata|Obsoleting|Security:|$)')"
    set -e
    PENDING_SECURITY="${sec//[^0-9]/}"
    PENDING_SECURITY="${PENDING_SECURITY:-0}"
    return 0
}

# ---------------------------------------------------------------------------
# Summary construction - built once, reused by every platform.
# ---------------------------------------------------------------------------
build_summary() {
    local log_file="$1" os_type="$2"

    UPGRADED_NAMES="$(parse_upgraded_packages "$log_file" "$os_type")"
    UPGRADED_NAMES="${UPGRADED_NAMES%$'\n'}"
    UPGRADED_COUNT=0
    if [[ -n "$UPGRADED_NAMES" ]]; then
        # shellcheck disable=SC2086
        set -- $UPGRADED_NAMES
        UPGRADED_COUNT=$#
    fi

    count_pending_updates "$os_type"

    local kept_back error_msg
    kept_back="$(parse_kept_back "$log_file")"
    error_msg="$(parse_last_error "$log_file")"

    # ---- status ----
    if [[ -n "$error_msg" ]]; then
        UPDATE_STATUS="error"
    elif [[ $UPGRADED_COUNT -gt 0 ]]; then
        UPDATE_STATUS="updated"
    elif [[ ${PENDING_TOTAL:-0} -gt 0 ]]; then
        UPDATE_STATUS="updates-available"
    else
        UPDATE_STATUS="no-updates"
    fi

    # ---- one-line summary ----
    case "$UPDATE_STATUS" in
        updated)           UPDATE_SUMMARY="${UPGRADED_COUNT} package(s) updated" ;;
        updates-available) UPDATE_SUMMARY="${PENDING_TOTAL} package(s) available" ;;
        no-updates)        UPDATE_SUMMARY="System is up to date" ;;
        error)             UPDATE_SUMMARY="Update run reported an error" ;;
    esac

    # ---- multi-line body ----
    local body=""
    if [[ $UPGRADED_COUNT -gt 0 ]]; then
        local shown
        shown="$(printf '%s' "$UPGRADED_NAMES" | tr ' ' '\n' | head -n "$MAX_PACKAGE_NAMES" | paste -sd', ' -)"
        body="✅ Updates Applied: ${UPGRADED_COUNT} package(s)"$'\n'"   ${shown}"
        if [[ $UPGRADED_COUNT -gt $MAX_PACKAGE_NAMES ]]; then
            body+=" ... and $((UPGRADED_COUNT - MAX_PACKAGE_NAMES)) more"
        fi
    fi

    if [[ ${PENDING_TOTAL:-0} -gt 0 ]]; then
        [[ -n "$body" ]] && body+=$'\n'
        if [[ ${PENDING_SECURITY:-0} -gt 0 ]]; then
            body+="📦 Still Pending: ${PENDING_TOTAL} package(s) (${PENDING_SECURITY} security)"
        else
            body+="📦 Still Pending: ${PENDING_TOTAL} package(s)"
        fi
        [[ -n "${PENDING_NAMES:-}" ]] && body+=$'\n'"   ${PENDING_NAMES}"
        if [[ ${PENDING_TOTAL} -gt $MAX_PACKAGE_NAMES ]]; then
            body+=" ... and $((PENDING_TOTAL - MAX_PACKAGE_NAMES)) more"
        fi
    fi

    if [[ -n "$kept_back" ]]; then
        [[ -n "$body" ]] && body+=$'\n'
        body+="⚠️  Held Back: ${kept_back}"
    fi

    if [[ -n "$error_msg" ]]; then
        [[ -n "$body" ]] && body+=$'\n'
        body+="❌ Error: ${error_msg}"
    fi

    if [[ -z "$body" ]]; then
        body="✅ System is up to date"
        if [[ ! -r "$log_file" ]]; then
            body+=$'\n'"ℹ️  No upgrade history yet (first run)"
        fi
    fi

    SUMMARY_BODY="$body"
}

# ---------------------------------------------------------------------------
# Webhook transport
# ---------------------------------------------------------------------------
validate_webhook() {
    local url="$1" platform="$2"
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "WARNING: $platform URL is not http(s), refusing to send"
        return 1
    fi
    case "$platform" in
        Discord)
            [[ "$url" =~ discord(app)?\.com/api/webhooks/ ]] || \
                log "NOTE: $platform URL does not look like a Discord webhook"
            ;;
        Slack)
            [[ "$url" =~ hooks\.slack\.com/services/ ]] || \
                log "NOTE: $platform URL does not look like a Slack webhook"
            ;;
        Teams)
            # Modern Teams webhooks are *.webhook.office.com (Power Automate);
            # the retired connector form was outlook.office.com/webhook/.
            [[ "$url" =~ (webhook\.office\.com|outlook\.office\.com/webhook/|logic\.azure\.com) ]] || \
                log "NOTE: $platform URL does not look like a Teams webhook"
            ;;
    esac
    return 0
}

# http_post <url> <payload-file> <platform> [method] [extra curl args...]
http_post() {
    local url="$1" payload_file="$2" platform="$3" method="${4:-POST}"
    shift 4 2>/dev/null || shift 3

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY_RUN: would send notification to $platform"
        return 0
    fi

    local i response http_code
    for ((i = 1; i <= RETRY_COUNT; i++)); do
        response="$(curl -sS -w '\n%{http_code}' --max-time "$CURL_TIMEOUT" \
            -H 'Content-Type: application/json' \
            -X "$method" -d @"$payload_file" "$@" "$url" 2>/dev/null || printf '\n000')"
        http_code="$(printf '%s' "$response" | tail -n1 | tr -cd '0-9')"
        http_code="${http_code:-0}"

        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            log "SUCCESS: sent notification to $platform (HTTP $http_code)"
            return 0
        fi
        log "WARNING: failed to send to $platform (HTTP $http_code, attempt $i/$RETRY_COUNT)"
        # 4xx other than 429 will not succeed on retry.
        if [[ "$http_code" -ge 400 && "$http_code" -lt 500 && "$http_code" -ne 429 ]]; then
            log "ERROR: $platform rejected the request, not retrying"
            return 1
        fi
        [[ $i -lt $RETRY_COUNT ]] && sleep "$RETRY_DELAY"
    done

    log "ERROR: all retry attempts failed for $platform"
    return 1
}

record_result() {
    local platform="$1" ok="$2"
    if [[ "$ok" == "true" ]]; then
        NOTIFICATION_SENT=true
    else
        ERRORS+="${platform}; "
    fi
}

# ---------------------------------------------------------------------------
# Platform senders
# ---------------------------------------------------------------------------
notify_discord() {
    local url="$1" tmp
    validate_webhook "$url" "Discord" || { record_result Discord false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    cat > "$tmp" <<EOF
{
  "username": "$(json_escape "$BOT_NAME")",
  "embeds": [
    {
      "title": "$(json_escape "$NOTIFICATION_TITLE")",
      "description": "$(json_escape "$NOTIFICATION_DESC")\n\n\`\`\`\n$(json_escape "$SUMMARY_BODY")\n\`\`\`",
      "color": $NOTIFICATION_COLOR,
      "timestamp": "$LAST_RUN_UTC",
      "footer": { "text": "$(json_escape "$BOT_NAME")" }
    }
  ]
}
EOF
    if http_post "$url" "$tmp" "Discord"; then record_result Discord true; else record_result Discord false; fi
}

notify_slack() {
    local url="$1" tmp
    validate_webhook "$url" "Slack" || { record_result Slack false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    cat > "$tmp" <<EOF
{
  "text": "$(json_escape "$NOTIFICATION_TITLE")",
  "blocks": [
    {
      "type": "header",
      "text": { "type": "plain_text", "text": "$(json_escape "$NOTIFICATION_HEADLINE")" }
    },
    {
      "type": "section",
      "fields": [
        { "type": "mrkdwn", "text": "*Host:*\n$(json_escape "$HOST_NAME")" },
        { "type": "mrkdwn", "text": "*Status:*\n$(json_escape "$UPDATE_SUMMARY")" }
      ]
    },
    {
      "type": "section",
      "text": { "type": "mrkdwn", "text": "\`\`\`\n$(json_escape "$SUMMARY_BODY")\n\`\`\`" }
    }
  ]
}
EOF
    if http_post "$url" "$tmp" "Slack"; then record_result Slack true; else record_result Slack false; fi
}

notify_teams() {
    local url="$1" tmp
    validate_webhook "$url" "Teams" || { record_result Teams false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    # Adaptive Card wrapped for a Power Automate "Post to Teams" flow, which is
    # what replaced the retired Office 365 MessageCard connectors.
    cat > "$tmp" <<EOF
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "contentUrl": null,
      "content": {
        "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
          { "type": "TextBlock", "size": "Medium", "weight": "Bolder",
            "text": "$(json_escape "$NOTIFICATION_TITLE")" },
          { "type": "FactSet", "facts": [
              { "title": "Host", "value": "$(json_escape "$HOST_NAME")" },
              { "title": "Status", "value": "$(json_escape "$UPDATE_SUMMARY")" },
              { "title": "When", "value": "$(json_escape "$LAST_RUN")" }
            ] },
          { "type": "TextBlock", "wrap": true, "fontType": "Monospace",
            "text": "$(json_escape "$SUMMARY_BODY")" }
        ]
      }
    }
  ]
}
EOF
    if http_post "$url" "$tmp" "Teams"; then record_result Teams true; else record_result Teams false; fi
}

notify_ntfy() {
    local url="$1" tmp
    validate_webhook "$url" "ntfy" || { record_result ntfy false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    cat > "$tmp" <<EOF
{
  "topic": "$(json_escape "${NTFY_TOPIC:-}")",
  "title": "$(json_escape "$NOTIFICATION_TITLE")",
  "message": "$(json_escape "$SUMMARY_BODY")",
  "priority": $NTFY_PRIORITY,
  "tags": ["package"]
}
EOF
    local -a auth=()
    [[ -n "${NTFY_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    if http_post "$url" "$tmp" "ntfy" POST "${auth[@]}"; then
        record_result ntfy true
    else
        record_result ntfy false
    fi
}

notify_gotify() {
    local url="$1" tmp
    validate_webhook "$url" "Gotify" || { record_result Gotify false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    cat > "$tmp" <<EOF
{
  "title": "$(json_escape "$NOTIFICATION_TITLE")",
  "message": "$(json_escape "$SUMMARY_BODY")",
  "priority": ${GOTIFY_PRIORITY:-5}
}
EOF
    local target="$url"
    [[ -n "${GOTIFY_TOKEN:-}" ]] && target="${url}?token=${GOTIFY_TOKEN}"
    if http_post "$target" "$tmp" "Gotify"; then record_result Gotify true; else record_result Gotify false; fi
}

notify_webhook_generic() {
    local url="$1" tmp
    validate_webhook "$url" "Webhook" || { record_result Webhook false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    cat > "$tmp" <<EOF
{
  "host": "$(json_escape "$HOST_NAME")",
  "status": "$(json_escape "$UPDATE_STATUS")",
  "summary": "$(json_escape "$UPDATE_SUMMARY")",
  "detail": "$(json_escape "$SUMMARY_BODY")",
  "upgraded_count": ${UPGRADED_COUNT:-0},
  "pending_total": ${PENDING_TOTAL:-0},
  "pending_security": ${PENDING_SECURITY:-0},
  "timestamp": "$LAST_RUN_UTC",
  "version": "$PATCH_GREMLIN_VERSION"
}
EOF
    if http_post "$url" "$tmp" "Webhook"; then record_result Webhook true; else record_result Webhook false; fi
}

# ---------------------------------------------------------------------------
# Matrix
#
# Prefers a long-lived access token. Password login is still supported but we
# now log out afterwards - the old code created a brand new device on every
# single run, so a daily notifier accumulated ~365 devices a year.
# ---------------------------------------------------------------------------
MATRIX_SESSION_TOKEN=""
MATRIX_SESSION_OWNED=false

matrix_login() {
    local tmp response
    make_temp; tmp="$MAKE_TEMP_RESULT"
    local localpart="$MATRIX_USERNAME"
    [[ "$MATRIX_USERNAME" =~ ^@([^:]+): ]] && localpart="${BASH_REMATCH[1]}"
    cat > "$tmp" <<EOF
{
  "type": "m.login.password",
  "identifier": { "type": "m.id.user", "user": "$(json_escape "$localpart")" },
  "password": "$(json_escape "$MATRIX_PASSWORD")",
  "initial_device_display_name": "$(json_escape "$BOT_NAME")"
}
EOF
    response="$(curl -sS --max-time "$CURL_TIMEOUT" -H 'Content-Type: application/json' \
        -X POST -d @"$tmp" "${MATRIX_HOMESERVER%/}/_matrix/client/v3/login" 2>/dev/null || true)"
    MATRIX_SESSION_TOKEN="$(printf '%s' "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)"
    if [[ -z "$MATRIX_SESSION_TOKEN" ]]; then
        local errcode
        errcode="$(printf '%s' "$response" | grep -o '"errcode":"[^"]*"' | cut -d'"' -f4 || true)"
        log "ERROR: Matrix login failed (${errcode:-unknown})"
        return 1
    fi
    MATRIX_SESSION_OWNED=true
    return 0
}

matrix_logout() {
    [[ "$MATRIX_SESSION_OWNED" == "true" ]] || return 0
    [[ -n "$MATRIX_SESSION_TOKEN" ]] || return 0
    curl -sS --max-time "$CURL_TIMEOUT" -X POST \
        -H "Authorization: Bearer $MATRIX_SESSION_TOKEN" \
        "${MATRIX_HOMESERVER%/}/_matrix/client/v3/logout" >/dev/null 2>&1 || true
    MATRIX_SESSION_OWNED=false
    MATRIX_SESSION_TOKEN=""
}

urlencode() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

notify_matrix_api() {
    local tmp txn url
    if [[ -n "${MATRIX_ACCESS_TOKEN:-}" ]]; then
        MATRIX_SESSION_TOKEN="$MATRIX_ACCESS_TOKEN"
    elif ! matrix_login; then
        record_result Matrix false
        return
    fi

    make_temp; tmp="$MAKE_TEMP_RESULT"
    local body="${NOTIFICATION_TITLE}"$'\n\n'"${UPDATE_SUMMARY} at ${LAST_RUN}"$'\n\n'"${SUMMARY_BODY}"
    cat > "$tmp" <<EOF
{ "msgtype": "m.text", "body": "$(json_escape "$body")" }
EOF
    txn="pg-$(date +%s)-$$"
    url="${MATRIX_HOMESERVER%/}/_matrix/client/v3/rooms/$(urlencode "$MATRIX_ROOM_ID")/send/m.room.message/${txn}"
    if http_post "$url" "$tmp" "Matrix" PUT -H "Authorization: Bearer $MATRIX_SESSION_TOKEN"; then
        record_result Matrix true
    else
        record_result Matrix false
    fi
}

notify_matrix_webhook() {
    local url="$1" tmp
    validate_webhook "$url" "Matrix" || { record_result Matrix false; return; }
    make_temp; tmp="$MAKE_TEMP_RESULT"
    local body="${NOTIFICATION_TITLE}"$'\n\n'"${UPDATE_SUMMARY} at ${LAST_RUN}"$'\n\n'"${SUMMARY_BODY}"
    cat > "$tmp" <<EOF
{
  "text": "$(json_escape "$body")",
  "format": "plain",
  "displayName": "$(json_escape "$BOT_NAME")"
}
EOF
    if http_post "$url" "$tmp" "Matrix"; then record_result Matrix true; else record_result Matrix false; fi
}

# ---------------------------------------------------------------------------
# Secret loading
# ---------------------------------------------------------------------------
file_is_safe() {
    local f="$1" mode owner
    [[ -r "$f" ]] || return 1
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo 777)"
    owner="$(stat -c '%u' "$f" 2>/dev/null || echo 65534)"
    # Reject group- or world-writable files, and files not owned by root.
    if [[ "${mode: -1}" =~ [2367] ]] || [[ "${mode: -2:1}" =~ [2367] ]]; then
        log "WARNING: skipping $f - writable by non-owner (mode $mode)"
        return 1
    fi
    if [[ "$owner" != "0" && "$(id -u)" == "0" ]]; then
        log "WARNING: skipping $f - not owned by root"
        return 1
    fi
    return 0
}

load_secrets() {
    # All notification variables start empty so `set -u` can never fire on them.
    DISCORD_WEBHOOK=""; TEAMS_WEBHOOK=""; SLACK_WEBHOOK=""
    MATRIX_WEBHOOK=""; MATRIX_HOMESERVER=""; MATRIX_USERNAME=""
    MATRIX_PASSWORD=""; MATRIX_ROOM_ID=""; MATRIX_ACCESS_TOKEN=""
    NTFY_URL=""; NTFY_TOPIC=""; NTFY_TOKEN=""; NTFY_PRIORITY=3
    GOTIFY_URL=""; GOTIFY_TOKEN=""; GOTIFY_PRIORITY=5
    GENERIC_WEBHOOK_URL=""

    # Read the root-only environment file directly so that running the script
    # by hand behaves the same as the systemd unit. Parsed as KEY=VALUE rather
    # than sourced - it is generated by the installer, but it holds the
    # Doppler token and should never be executable input.
    if [[ -f "$ENV_FILE" ]] && file_is_safe "$ENV_FILE"; then
        local line key value
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            key="${line%%=*}"; value="${line#*=}"
            [[ "$key" =~ ^(SECRET_MODE|DOPPLER_TOKEN|DOPPLER_[A-Z_]+_SECRET)$ ]] || continue
            # Only fill in what the environment has not already provided.
            [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
        done < "$ENV_FILE"
    fi

    if [[ -f "$CONFIG_FILE" ]] && file_is_safe "$CONFIG_FILE"; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    if [[ -f "$SECRETS_FILE" ]] && file_is_safe "$SECRETS_FILE"; then
        # shellcheck source=/dev/null
        source "$SECRETS_FILE"
        SECRET_MODE="local"
    fi

    [[ "${SECRET_MODE:-doppler}" == "doppler" ]] || return 0

    DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
    DOPPLER_TEAMS_SECRET="${DOPPLER_TEAMS_SECRET:-UPDATE_NOTIFIER_TEAMS_WEBHOOK}"
    DOPPLER_SLACK_SECRET="${DOPPLER_SLACK_SECRET:-UPDATE_NOTIFIER_SLACK_WEBHOOK}"
    DOPPLER_MATRIX_SECRET="${DOPPLER_MATRIX_SECRET:-UPDATE_NOTIFIER_MATRIX_WEBHOOK}"
    DOPPLER_MATRIX_HOMESERVER_SECRET="${DOPPLER_MATRIX_HOMESERVER_SECRET:-UPDATE_NOTIFIER_MATRIX_HOMESERVER}"
    DOPPLER_MATRIX_USERNAME_SECRET="${DOPPLER_MATRIX_USERNAME_SECRET:-UPDATE_NOTIFIER_MATRIX_USERNAME}"
    DOPPLER_MATRIX_PASSWORD_SECRET="${DOPPLER_MATRIX_PASSWORD_SECRET:-UPDATE_NOTIFIER_MATRIX_PASSWORD}"
    DOPPLER_MATRIX_ROOM_ID_SECRET="${DOPPLER_MATRIX_ROOM_ID_SECRET:-UPDATE_NOTIFIER_MATRIX_ROOM_ID}"

    if ! command -v doppler >/dev/null 2>&1; then
        log "ERROR: Doppler CLI is not installed (https://docs.doppler.com/docs/install-cli)"
        return 1
    fi
    local doppler_error
    if ! doppler_error="$(doppler me 2>&1)"; then
        log "ERROR: Doppler authentication failed - run 'doppler login'"
        log "Doppler said: $(printf '%s' "$doppler_error" | head -1 | sed 's/[Tt]oken[^ ]*/[REDACTED]/g')"
        return 1
    fi

    doppler_get() { doppler secrets get "$1" --plain 2>/dev/null || true; }
    DISCORD_WEBHOOK="$(doppler_get "$DOPPLER_DISCORD_SECRET")"
    TEAMS_WEBHOOK="$(doppler_get "$DOPPLER_TEAMS_SECRET")"
    SLACK_WEBHOOK="$(doppler_get "$DOPPLER_SLACK_SECRET")"
    MATRIX_WEBHOOK="$(doppler_get "$DOPPLER_MATRIX_SECRET")"
    MATRIX_HOMESERVER="$(doppler_get "$DOPPLER_MATRIX_HOMESERVER_SECRET")"
    MATRIX_USERNAME="$(doppler_get "$DOPPLER_MATRIX_USERNAME_SECRET")"
    MATRIX_PASSWORD="$(doppler_get "$DOPPLER_MATRIX_PASSWORD_SECRET")"
    MATRIX_ROOM_ID="$(doppler_get "$DOPPLER_MATRIX_ROOM_ID_SECRET")"
    MATRIX_ACCESS_TOKEN="$(doppler_get "${DOPPLER_MATRIX_TOKEN_SECRET:-UPDATE_NOTIFIER_MATRIX_ACCESS_TOKEN}")"
    NTFY_URL="$(doppler_get "${DOPPLER_NTFY_URL_SECRET:-UPDATE_NOTIFIER_NTFY_URL}")"
    NTFY_TOPIC="$(doppler_get "${DOPPLER_NTFY_TOPIC_SECRET:-UPDATE_NOTIFIER_NTFY_TOPIC}")"
    NTFY_TOKEN="$(doppler_get "${DOPPLER_NTFY_TOKEN_SECRET:-UPDATE_NOTIFIER_NTFY_TOKEN}")"
    GOTIFY_URL="$(doppler_get "${DOPPLER_GOTIFY_URL_SECRET:-UPDATE_NOTIFIER_GOTIFY_URL}")"
    GOTIFY_TOKEN="$(doppler_get "${DOPPLER_GOTIFY_TOKEN_SECRET:-UPDATE_NOTIFIER_GOTIFY_TOKEN}")"
    GENERIC_WEBHOOK_URL="$(doppler_get "${DOPPLER_WEBHOOK_SECRET:-UPDATE_NOTIFIER_WEBHOOK_URL}")"
    return 0
}

validate_environment() {
    local errors=0 cmd
    for cmd in curl grep awk sed tail; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR: required command not found: $cmd"
            errors=$((errors + 1))
        fi
    done
    return "$errors"
}

write_state() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    cat > "$STATE_DIR/state" 2>/dev/null <<EOF || true
last_run_epoch=$(date +%s)
last_status=$UPDATE_STATUS
upgraded_count=${UPGRADED_COUNT:-0}
pending_total=${PENDING_TOTAL:-0}
pending_security=${PENDING_SECURITY:-0}
notification_sent=${NOTIFICATION_SENT}
version=$PATCH_GREMLIN_VERSION
EOF
}

# ---------------------------------------------------------------------------
# Doppler secret-name defaults
# ---------------------------------------------------------------------------
DOPPLER_DISCORD_SECRET="${DOPPLER_DISCORD_SECRET:-UPDATE_NOTIFIER_DISCORD_WEBHOOK}"
DOPPLER_MATRIX_SECRET="${DOPPLER_MATRIX_SECRET:-UPDATE_NOTIFIER_MATRIX_WEBHOOK}"
DOPPLER_MATRIX_HOMESERVER_SECRET="${DOPPLER_MATRIX_HOMESERVER_SECRET:-UPDATE_NOTIFIER_MATRIX_HOMESERVER}"
DOPPLER_MATRIX_USERNAME_SECRET="${DOPPLER_MATRIX_USERNAME_SECRET:-UPDATE_NOTIFIER_MATRIX_USERNAME}"
DOPPLER_MATRIX_PASSWORD_SECRET="${DOPPLER_MATRIX_PASSWORD_SECRET:-UPDATE_NOTIFIER_MATRIX_PASSWORD}"
DOPPLER_MATRIX_ROOM_ID_SECRET="${DOPPLER_MATRIX_ROOM_ID_SECRET:-UPDATE_NOTIFIER_MATRIX_ROOM_ID}"
DOPPLER_TEAMS_SECRET="${DOPPLER_TEAMS_SECRET:-UPDATE_NOTIFIER_TEAMS_WEBHOOK}"
DOPPLER_SLACK_SECRET="${DOPPLER_SLACK_SECRET:-UPDATE_NOTIFIER_SLACK_WEBHOOK}"

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -V|--version) echo "patch-gremlin $PATCH_GREMLIN_VERSION"; exit 0 ;;
            -n|--dry-run) DRY_RUN=true ;;
            *) log "ERROR: unknown option: $1"; usage >&2; exit 2 ;;
        esac
        shift
    done

    trap cleanup EXIT

    validate_environment || { log "ERROR: environment validation failed"; exit 1; }

    # Serialise: the systemd timer and the post-upgrade hook can otherwise
    # fire concurrently and send duplicate notifications.
    # NB: `exec 9>f 2>/dev/null` would redirect the shell's stderr permanently,
    # swallowing every subsequent log line. Open the fd only once we know the
    # path is writable.
    if command -v flock >/dev/null 2>&1 && [[ "${PATCH_GREMLIN_NO_LOCK:-}" != "true" ]] &&
       : 2>/dev/null >>"$LOCK_FILE"; then
        exec 9>>"$LOCK_FILE"
        if ! flock -n 9; then
            log "INFO: another Patch Gremlin run is in progress, exiting"
            exit 0
        fi
    fi

    OS_TYPE="$(detect_os_type)"
    LOG_FILE="$(detect_log_file "$OS_TYPE")"
    HOST_NAME="$(hostname)"
    LAST_RUN="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    LAST_RUN_UTC="$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"

    if ! load_secrets; then
        exit 1
    fi

    local matrix_mode="none"
    if [[ -n "$MATRIX_WEBHOOK" ]]; then
        matrix_mode="webhook"
    elif [[ -n "$MATRIX_HOMESERVER" && -n "$MATRIX_ROOM_ID" ]] &&
         { [[ -n "$MATRIX_ACCESS_TOKEN" ]] || [[ -n "$MATRIX_USERNAME" && -n "$MATRIX_PASSWORD" ]]; }; then
        matrix_mode="api"
    fi

    if [[ -z "$DISCORD_WEBHOOK$TEAMS_WEBHOOK$SLACK_WEBHOOK$NTFY_URL$GOTIFY_URL$GENERIC_WEBHOOK_URL" ]] &&
       [[ "$matrix_mode" == "none" ]]; then
        log "ERROR: No notification methods configured."
        if [[ "${SECRET_MODE:-doppler}" == "local" ]]; then
            log "Configure at least one webhook in $SECRETS_FILE, or re-run the setup script."
        else
            log "Add at least one secret in Doppler (e.g. $DOPPLER_DISCORD_SECRET), then retry."
        fi
        exit 1
    fi

    # Snapshot the log so an in-flight writer cannot change it mid-parse.
    local snapshot=""
    if [[ -r "$LOG_FILE" ]]; then
        make_temp; snapshot="$MAKE_TEMP_RESULT"
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$snapshot" 2>/dev/null || cp "$LOG_FILE" "$snapshot"
    else
        log "WARNING: log file $LOG_FILE not readable; reporting on pending updates only"
    fi

    build_summary "$snapshot" "$OS_TYPE"

    if [[ "$NOTIFY_ON" == "changes" && "$UPDATE_STATUS" == "no-updates" ]]; then
        log "INFO: nothing changed and NOTIFY_ON=changes, skipping notification"
        NOTIFICATION_SENT=true
        write_state
        exit 0
    fi

    case "$UPDATE_STATUS" in
        updated)
            NOTIFICATION_TITLE="System Updates Applied on $HOST_NAME"
            NOTIFICATION_HEADLINE="✅ System Updates Applied"
            NOTIFICATION_COLOR=$COLOR_GREEN ;;
        updates-available)
            NOTIFICATION_TITLE="System Updates Available on $HOST_NAME"
            NOTIFICATION_HEADLINE="📦 System Updates Available"
            NOTIFICATION_COLOR=$COLOR_ORANGE ;;
        no-updates)
            NOTIFICATION_TITLE="System Update Check Complete on $HOST_NAME"
            NOTIFICATION_HEADLINE="✅ Update Check Complete"
            NOTIFICATION_COLOR=$COLOR_BLUE ;;
        error)
            NOTIFICATION_TITLE="System Update Error on $HOST_NAME"
            NOTIFICATION_HEADLINE="❌ System Update Error"
            NOTIFICATION_COLOR=$COLOR_RED ;;
    esac
    NOTIFICATION_DESC="$UPDATE_SUMMARY at $LAST_RUN"

    log "INFO: os=$OS_TYPE status=$UPDATE_STATUS summary=$UPDATE_SUMMARY"

    NOTIFICATION_SENT=false
    ERRORS=""

    [[ -n "$DISCORD_WEBHOOK" ]]        && notify_discord "$DISCORD_WEBHOOK"
    [[ -n "$SLACK_WEBHOOK" ]]          && notify_slack "$SLACK_WEBHOOK"
    [[ -n "$TEAMS_WEBHOOK" ]]          && notify_teams "$TEAMS_WEBHOOK"
    [[ -n "$NTFY_URL" ]]               && notify_ntfy "$NTFY_URL"
    [[ -n "$GOTIFY_URL" ]]             && notify_gotify "$GOTIFY_URL"
    [[ -n "$GENERIC_WEBHOOK_URL" ]]    && notify_webhook_generic "$GENERIC_WEBHOOK_URL"
    [[ "$matrix_mode" == "webhook" ]]  && notify_matrix_webhook "$MATRIX_WEBHOOK"
    [[ "$matrix_mode" == "api" ]]      && notify_matrix_api

    write_state

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY_RUN: notification simulation complete"
        exit 0
    fi
    if [[ "$NOTIFICATION_SENT" == "true" ]]; then
        [[ -n "$ERRORS" ]] && log "WARNING: some platforms failed: ${ERRORS%; }"
        log "SUCCESS: Notification delivery complete"
        exit 0
    fi
    log "ERROR: All notification attempts failed"
    log "Failed platforms: ${ERRORS%; }"
    exit 1
}

# When sourced by the test-suite, PATCH_GREMLIN_SOURCE_ONLY is set and we stop
# here, exposing the functions above without running anything.
if [[ -z "${PATCH_GREMLIN_SOURCE_ONLY:-}" ]]; then
    main "$@"
fi
