#!/usr/bin/env bats
# Unit + integration tests for update-notifier.sh

load test_helper

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

# --------------------------------------------------------------------------
# json_escape
# --------------------------------------------------------------------------

@test "json_escape: escapes double quotes" {
    load_notifier
    run json_escape 'he said "hi"'
    [ "$status" -eq 0 ]
    [ "$output" = 'he said \"hi\"' ]
}

@test "json_escape: escapes backslashes" {
    load_notifier
    run json_escape 'C:\path\to'
    [ "$status" -eq 0 ]
    [ "$output" = 'C:\\path\\to' ]
}

@test "json_escape: escapes newlines as literal \\n" {
    load_notifier
    result="$(json_escape "$(printf 'a\nb')")"
    [ "$result" = 'a\nb' ]
}

@test "json_escape: neutralises control characters into valid JSON" {
    load_notifier
    esc="$(json_escape "$(printf 'a\x07b')")"
    printf '{"k":"%s"}' "$esc" > "$SANDBOX/c.json"
    run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SANDBOX/c.json"
    [ "$status" -eq 0 ]
}

@test "json_escape: output embeds into valid JSON" {
    load_notifier
    esc="$(json_escape 'quote " backslash \ tab	end')"
    printf '{"k":"%s"}' "$esc" > "$SANDBOX/t.json"
    run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SANDBOX/t.json"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# parse_upgraded_packages  (regression: names are on the SAME line as marker)
# --------------------------------------------------------------------------

@test "parse_upgraded_packages: extracts names from real u-u log format" {
    load_notifier
    run parse_upgraded_packages "$FIXTURES/uu-upgraded.log" debian
    [ "$status" -eq 0 ]
    [ "$output" = "libssl3 openssl curl" ]
}

@test "parse_upgraded_packages: uses only the most recent run" {
    load_notifier
    run parse_upgraded_packages "$FIXTURES/uu-multi-run.log" debian
    [ "$status" -eq 0 ]
    [ "$output" = "newpkg1 newpkg2" ]
    [[ "$output" != *"oldpkg"* ]]
}

@test "parse_upgraded_packages: empty when nothing upgraded" {
    load_notifier
    run parse_upgraded_packages "$FIXTURES/uu-no-updates.log" debian
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "parse_upgraded_packages: rhel dnf log" {
    load_notifier
    run parse_upgraded_packages "$FIXTURES/dnf-upgraded.log" rhel
    [ "$status" -eq 0 ]
    [[ "$output" == *"openssl"* ]]
    [[ "$output" == *"curl"* ]]
}

@test "parse_upgraded_packages: missing file is not fatal" {
    load_notifier
    run parse_upgraded_packages "$SANDBOX/nope.log" debian
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --------------------------------------------------------------------------
# End-to-end: status classification
# --------------------------------------------------------------------------

run_notifier() {
    run env PATH="$HELPERS:$PATH" \
        STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" \
        PATCH_GREMLIN_SECRETS_FILE="$PATCH_GREMLIN_SECRETS_FILE" \
        PATCH_GREMLIN_CONFIG_FILE="$PATCH_GREMLIN_CONFIG_FILE" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        "$@" \
        bash "$REPO_ROOT/update-notifier.sh"
}

@test "e2e: reports 'updated' when packages were actually upgraded" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE=""
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Updates Applied"* ]]
}

@test "e2e: does NOT flip to no-updates when upgrades happened and more are pending" {
    # This is the regression that made Patch Gremlin report "No updates applied"
    # on exactly the runs where it did apply updates.
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE="vim nano"
    [ "$status" -eq 0 ]
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Updates Applied"* ]]
    [[ "$title" != *"No updates"* ]]
}

@test "e2e: reports 'no-updates' on a clean run" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE=""
    [ "$status" -eq 0 ]
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Check Complete"* ]]
}

@test "e2e: reports 'updates-available' when only pending updates exist" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE="vim nano htop"
    [ "$status" -eq 0 ]
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Updates Available"* ]]
}

# --------------------------------------------------------------------------
# End-to-end: JSON safety with hostile log content
# --------------------------------------------------------------------------

@test "e2e: log content with quotes/backslashes still yields valid JSON" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-error-quotes.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE=""
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
}

@test "e2e: hostname with a quote still yields valid JSON" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE="" \
                 STUB_HOSTNAME='we"ird\host'
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
}

@test "e2e: all four platform payloads are valid JSON" {
    write_secrets '
DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"
SLACK_WEBHOOK="https://hooks.slack.com/services/T/B/x"
TEAMS_WEBHOOK="https://example.webhook.office.com/webhookb2/abc"
MATRIX_HOMESERVER="https://matrix.example.org"
MATRIX_USERNAME="@bot:example.org"
MATRIX_PASSWORD="hunter2"
MATRIX_ROOM_ID="!room:example.org"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-kept-back.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE=""
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
}

# --------------------------------------------------------------------------
# Regression: RHEL dnf exit 100
# --------------------------------------------------------------------------

@test "e2e: dnf check-update exit 100 does not abort the notifier" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/dnf-no-updates.log" \
                 PATCH_GREMLIN_OS_TYPE=rhel STUB_UPGRADABLE="openssl curl"
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Updates Available"* ]]
}

# --------------------------------------------------------------------------
# Regression: unbound variables in local mode
# --------------------------------------------------------------------------

@test "local mode with a missing secrets file fails cleanly, not with 'unbound variable'" {
    rm -f "$PATCH_GREMLIN_SECRETS_FILE"
    run_notifier SECRET_MODE=local PATCH_GREMLIN_OS_TYPE=debian \
                 PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log"
    [ "$status" -ne 0 ]
    [[ "$output" != *"unbound variable"* ]]
    [[ "$output" == *"No notification methods configured"* ]]
}

@test "local mode with a partially-filled secrets file works" {
    write_secrets 'SLACK_WEBHOOK="https://hooks.slack.com/services/T/B/x"'
    run_notifier PATCH_GREMLIN_OS_TYPE=debian \
                 PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log"
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
}

# --------------------------------------------------------------------------
# Retry / HTTP handling
# --------------------------------------------------------------------------

@test "send failure is reported as a non-zero exit" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_HTTP_CODE=500 \
                 PATCH_GREMLIN_RETRY_COUNT=2 PATCH_GREMLIN_RETRY_DELAY=0
    [ "$status" -ne 0 ]
    [[ "$output" == *"All notification attempts failed"* ]]
}

@test "curl transport failure logs a numeric code, not a literal backslash-n" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_HTTP_CODE=000 \
                 PATCH_GREMLIN_RETRY_COUNT=1 PATCH_GREMLIN_RETRY_DELAY=0
    [[ "$output" != *'\n000'* ]]
    [[ "$output" != *"syntax error"* ]]
}

@test "dry run sends nothing and exits 0" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian PATCH_GREMLIN_DRY_RUN=true
    [ "$status" -eq 0 ]
    [ ! -e "$STUB_CAPTURE_DIR/payload-1" ]
}

# --------------------------------------------------------------------------
# Housekeeping
# --------------------------------------------------------------------------

@test "no temp files are leaked after a run with Matrix enabled" {
    write_secrets '
DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"
MATRIX_HOMESERVER="https://matrix.example.org"
MATRIX_USERNAME="@bot:example.org"
MATRIX_PASSWORD="hunter2"
MATRIX_ROOM_ID="!room:example.org"'
    mkdir -p "$SANDBOX/tmp"
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian TMPDIR="$SANDBOX/tmp"
    [ "$status" -eq 0 ]
    leaked=$(find "$SANDBOX/tmp" -type f | wc -l)
    [ "$leaked" -eq 0 ]
}

@test "--version prints a version" {
    run bash "$REPO_ROOT/update-notifier.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "--help prints usage" {
    run bash "$REPO_ROOT/update-notifier.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

# --------------------------------------------------------------------------
# Additional platforms
# --------------------------------------------------------------------------

@test "ntfy: sends a valid payload with the topic and bearer token" {
    write_secrets '
NTFY_URL="https://ntfy.example.com"
NTFY_TOPIC="servers"
NTFY_TOKEN="tk_secret"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
    [ "$(payload_field "$STUB_CAPTURE_DIR/payload-1" topic)" = "servers" ]
    grep -q 'Authorization: Bearer tk_secret' "$STUB_CAPTURE_DIR/call-1"
}

@test "ntfy: works without a token (empty auth array under set -u)" {
    write_secrets '
NTFY_URL="https://ntfy.example.com"
NTFY_TOPIC="servers"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
    assert_payloads_valid_json
}

@test "gotify: appends the token to the URL and sends valid JSON" {
    write_secrets '
GOTIFY_URL="https://gotify.example.com/message"
GOTIFY_TOKEN="AtokenX"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
    grep -q 'token=AtokenX' "$STUB_CAPTURE_DIR/call-1"
}

@test "generic webhook: emits machine-readable fields" {
    write_secrets 'GENERIC_WEBHOOK_URL="https://example.com/hook"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE="vim nano"
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
    [ "$(payload_field "$STUB_CAPTURE_DIR/payload-1" status)" = "updated" ]
    [ "$(payload_field "$STUB_CAPTURE_DIR/payload-1" upgraded_count)" = "3" ]
    [ "$(payload_field "$STUB_CAPTURE_DIR/payload-1" pending_total)" = "2" ]
}

@test "matrix: a preset access token skips the login round trip" {
    write_secrets '
MATRIX_HOMESERVER="https://matrix.example.org"
MATRIX_ACCESS_TOKEN="syt_preset"
MATRIX_ROOM_ID="!room:example.org"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    ! grep -rq '/login' "$STUB_CAPTURE_DIR"/call-* 2>/dev/null
    grep -q 'Authorization: Bearer syt_preset' "$STUB_CAPTURE_DIR"/call-1
}

@test "matrix: password login is followed by a logout" {
    # v1 registered a fresh device on every run and never logged out.
    write_secrets '
MATRIX_HOMESERVER="https://matrix.example.org"
MATRIX_USERNAME="@bot:example.org"
MATRIX_PASSWORD="hunter2"
MATRIX_ROOM_ID="!room:example.org"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    grep -rq '/_matrix/client/v3/login' "$STUB_CAPTURE_DIR"/call-*
    grep -rq '/_matrix/client/v3/logout' "$STUB_CAPTURE_DIR"/call-*
    # and never the deprecated r0 API
    ! grep -rq '/client/r0/' "$STUB_CAPTURE_DIR"/call-*
}

@test "notifier reads /etc/update-notifier/env itself when run by hand" {
    rm -f "$PATCH_GREMLIN_SECRETS_FILE"
    printf 'SECRET_MODE=local\n' > "$SANDBOX/envfile"
    chmod 600 "$SANDBOX/envfile"
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_ENV_FILE="$SANDBOX/envfile" \
                 PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
}

@test "NOTIFY_ON=changes stays silent when nothing changed" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log" \
                 PATCH_GREMLIN_OS_TYPE=debian PATCH_GREMLIN_NOTIFY_ON=changes
    [ "$status" -eq 0 ]
    [ ! -e "$STUB_CAPTURE_DIR/payload-1" ]
}

@test "NOTIFY_ON=changes still reports when packages were upgraded" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian PATCH_GREMLIN_NOTIFY_ON=changes
    [ "$status" -eq 0 ]
    assert_payloads_valid_json
}

@test "state file is written for the monitoring integrations" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_UPGRADABLE="vim"
    [ "$status" -eq 0 ]
    [ -r "$PATCH_GREMLIN_STATE_DIR/state" ]
    grep -q 'last_status=updated' "$PATCH_GREMLIN_STATE_DIR/state"
    grep -q 'upgraded_count=3' "$PATCH_GREMLIN_STATE_DIR/state"
    grep -q 'notification_sent=true' "$PATCH_GREMLIN_STATE_DIR/state"
}

@test "an error in the upgrade log is surfaced as an error status" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-error-quotes.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Error"* ]]
}

@test "held-back packages appear in the summary" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-kept-back.log" \
                 PATCH_GREMLIN_OS_TYPE=debian
    [ "$status" -eq 0 ]
    desc="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.description)"
    [[ "$desc" == *"Held Back"* ]]
    [[ "$desc" == *"linux-image-amd64"* ]]
}

@test "security updates are counted separately from the total" {
    write_secrets 'GENERIC_WEBHOOK_URL="https://example.com/hook"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log" \
                 PATCH_GREMLIN_OS_TYPE=debian \
                 STUB_UPGRADABLE="vim nano" STUB_UPGRADABLE_SECURITY="openssl libssl3"
    [ "$status" -eq 0 ]
    [ "$(payload_field "$STUB_CAPTURE_DIR/payload-1" pending_total)" = "4" ]
    [ "$(payload_field "$STUB_CAPTURE_DIR/payload-1" pending_security)" = "2" ]
}

# --------------------------------------------------------------------------
# Log visibility
# --------------------------------------------------------------------------

@test "log output survives INVOCATION_ID being set (CI / systemd-spawned shells)" {
    # Regression: log() used to suppress stderr whenever INVOCATION_ID was
    # set. systemd exports it to anything it starts - including CI runners -
    # so every diagnostic vanished in exactly those environments.
    rm -f "$PATCH_GREMLIN_SECRETS_FILE"
    run_notifier SECRET_MODE=local INVOCATION_ID=deadbeefcafe \
                 PATCH_GREMLIN_OS_TYPE=debian \
                 PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No notification methods configured"* ]]
}

@test "log output survives JOURNAL_STREAM being set" {
    rm -f "$PATCH_GREMLIN_SECRETS_FILE"
    run_notifier SECRET_MODE=local JOURNAL_STREAM=8:12345 \
                 PATCH_GREMLIN_OS_TYPE=debian \
                 PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-no-updates.log"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No notification methods configured"* ]]
}

@test "failure reporting is visible under systemd-style environments" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian STUB_HTTP_CODE=500 \
                 INVOCATION_ID=deadbeefcafe JOURNAL_STREAM=8:12345 \
                 PATCH_GREMLIN_RETRY_COUNT=1 PATCH_GREMLIN_RETRY_DELAY=0
    [ "$status" -ne 0 ]
    [[ "$output" == *"All notification attempts failed"* ]]
}

# --------------------------------------------------------------------------
# hostname resolution
#
# `hostname` is not coreutils: it is absent from minimal Fedora/RHEL images.
# A bare $(hostname) aborted the whole notifier under `set -e` there. These
# tests deliberately build a PATH WITHOUT the hostname stub, because the stub
# is what hid this bug from the suite in the first place.
# --------------------------------------------------------------------------

# A complete, self-contained PATH that deliberately lacks hostname and
# hostnamectl: the command stubs plus symlinks to the real utilities the
# notifier needs. Simulating absence by trimming the system PATH is the only
# way to reproduce the minimal-image failure, since this host has hostname.
helpers_without_hostname() {
    local dir="$SANDBOX/nohost"
    mkdir -p "$dir"
    local f base
    for f in "$HELPERS"/*; do
        base="$(basename "$f")"
        [[ "$base" == "hostname" || "$base" == "hostnamectl" ]] && continue
        cp "$f" "$dir/"
    done
    local b path
    for b in bash env date grep sed awk tail head tr wc cut sort comm mktemp \
             rm cat paste stat find sleep mkdir cp chmod id flock python3 \
             dirname basename; do
        [[ -e "$dir/$b" ]] && continue
        path="$(command -v "$b" 2>/dev/null || true)"
        [[ -n "$path" ]] && ln -sf "$path" "$dir/$b"
    done
    # Sanity: the point of this helper is that hostname is NOT reachable.
    if PATH="$dir" command -v hostname >/dev/null 2>&1; then
        echo "helpers_without_hostname: hostname still reachable" >&2
        return 1
    fi
    printf '%s' "$dir"
}

@test "resolve_hostname: falls back when the hostname binary is missing" {
    load_notifier
    # A PATH with no hostname and no hostnamectl at all.
    result="$(PATH="$SANDBOX" HOSTNAME=fallback-host resolve_hostname)"
    [ -n "$result" ]
    [ "$result" != "unknown-host" ]
    [ "$result" = "fallback-host" ]
}

@test "resolve_hostname: never returns empty, even with nothing to go on" {
    load_notifier
    result="$(PATH="$SANDBOX" HOSTNAME="" resolve_hostname)"
    [ -n "$result" ]
}

@test "resolve_hostname: PATCH_GREMLIN_HOSTNAME wins" {
    load_notifier
    result="$(PATCH_GREMLIN_HOSTNAME=web01.example.com resolve_hostname)"
    [ "$result" = "web01.example.com" ]
}

@test "e2e: notifier works on a host with no hostname binary" {
    # Reproduces the fedora:41 CI failure: the notifier died with
    # "hostname: command not found" before sending anything.
    nohost="$(helpers_without_hostname)"
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run env PATH="$nohost" \
        STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" \
        PATCH_GREMLIN_SECRETS_FILE="$PATCH_GREMLIN_SECRETS_FILE" \
        PATCH_GREMLIN_CONFIG_FILE="$PATCH_GREMLIN_CONFIG_FILE" \
        PATCH_GREMLIN_ENV_FILE="$SANDBOX/nonexistent-env" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
        PATCH_GREMLIN_OS_TYPE=debian \
        bash "$REPO_ROOT/update-notifier.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"hostname: command not found"* ]]
    assert_payloads_valid_json
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"Updates Applied"* ]]
    # A real host name still made it into the notification.
    [[ -n "$title" ]]
}

@test "e2e: PATCH_GREMLIN_HOSTNAME appears in the notification title" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
                 PATCH_GREMLIN_OS_TYPE=debian \
                 PATCH_GREMLIN_HOSTNAME=web01.example.com
    [ "$status" -eq 0 ]
    title="$(payload_field "$STUB_CAPTURE_DIR/payload-1" embeds.0.title)"
    [[ "$title" == *"web01.example.com"* ]]
}
