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
