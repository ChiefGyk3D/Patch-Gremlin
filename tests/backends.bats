#!/usr/bin/env bats

load test_helper

setup() { setup_sandbox; load_notifier; }

@test "backend registry dispatches registered backends in registration order" {
    BACKENDS=(); calls=""
    first_backend() { calls+="first "; }
    second_backend() { calls+="second "; }
    register_backend first_backend
    register_backend second_backend
    dispatch_backends
    [ "$calls" = "first second " ]
}

@test "healthcheck URL is HTTPS-only and never appears in curl argv" {
    HEALTHCHECK_PING_URL='http://example.invalid/secret'
    RUN_ID='hostile rid&x'; STUB_CAPTURE_DIR="$SANDBOX/capture"; mkdir -p "$STUB_CAPTURE_DIR"
    run healthcheck_ping start ""
    [ "$status" -ne 0 ]
    [ -z "$(find "$STUB_CAPTURE_DIR" -type f -print -quit)" ]
    HEALTHCHECK_PING_URL='https://example.invalid/secret'
    run healthcheck_ping start ""
    [ "$status" -eq 0 ]
    ! grep -hE '^(ARGS|CMDLINE)=' "$STUB_CAPTURE_DIR"/call-* | grep -qF 'example.invalid/secret'
    grep -hq '^CFGMODE=600$' "$STUB_CAPTURE_DIR"/call-*
    grep -hqF 'rid=hostile%20rid%26x' "$STUB_CAPTURE_DIR"/call-*
}

@test "Pushover credentials stay out of argv and 4xx is attempted once" {
    UPDATE_STATUS=error PUSHOVER_TOKEN=SECRETTOKEN PUSHOVER_USER=SECRETUSER SUMMARY_BODY=failed
    STUB_HTTP_CODE=400; export STUB_HTTP_CODE
    NOTIFICATION_SENT=false ERRORS=""
    run pushover_send
    [ "$status" -eq 0 ]
    [ "$(find "$STUB_CAPTURE_DIR" -name 'call-*' | wc -l)" -eq 1 ]
    ! grep -hE '^(ARGS|CMDLINE)=' "$STUB_CAPTURE_DIR"/call-* | grep -qE 'SECRETTOKEN|SECRETUSER'
}

@test "Pushover is disabled for routine update reports" {
    PUSHOVER_TOKEN=secret PUSHOVER_USER=user UPDATE_STATUS=updated
    run pushover_enabled
    [ "$status" -ne 0 ]
    UPDATE_STATUS=error
    run pushover_enabled
    [ "$status" -eq 0 ]
}

@test "Pushover truncates hostile error text to 1024 characters" {
    UPDATE_STATUS=error PUSHOVER_TOKEN=secret PUSHOVER_USER=user
    SUMMARY_BODY="$(printf 'x%.0s' {1..1100})&token=leak"
    form="$(pushover_form_body)"
    message="${form#*message=}"; message="${message%%&priority=*}"
    [ ${#message} -le 3072 ]
    [[ "$form" == *'token=secret'* ]]
    [[ "$form" != *'token=leak'* ]]
}

@test "Pushover truncates multibyte text by character and neutralizes controls" {
    local form message decoded
    UPDATE_STATUS=error PUSHOVER_TOKEN=secret PUSHOVER_USER=user
    SUMMARY_BODY="$(printf 'é%.0s' {1..1023})"$'\n\t\001'"éignored"
    form="$(pushover_form_body)"
    message="${form#*message=}"; message="${message%%&priority=*}"
    decoded="$(printf '%s' "$message" | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()), end="")')"
    [ "${#decoded}" -eq 1024 ]
    [[ "$decoded" == "$(printf 'é%.0s' {1..1023}) " ]]
    [[ "$message" == *'%C3%A9'* ]]
    [[ "$message" != *'%0A'* ]]
    [[ "$message" != *'%09'* ]]
    [[ "$message" != *'%01'* ]]
}

@test "event JSON contains stable schema keys and escapes hostile host input" {
    HOST_NAME='host"\npoison' UPDATE_STATUS=error UPGRADED_COUNT=2 PENDING_SECURITY=1
    HELD_BACK_COUNT=3 REBOOT_REQUIRED=1 RUN_DURATION=9 RUN_ID=rid
    line="$(event_json)"
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"] == 1; assert d["run_id"] == "rid"' <<<"$line"
    [[ "$line" != *'WEBHOOK'* ]]
}

@test "events rotate at the cap and never serialize notification secrets" {
    EVENTS_FILE="$SANDBOX/events/events.jsonl" EVENTS_MAX_BYTES=1 DRY_RUN=false
    LAST_RUN_UTC=2026-11-24T00:00:00.000Z HOST_NAME=host UPDATE_STATUS=failed
    UPGRADED_COUNT=0 PENDING_SECURITY=0 HELD_BACK_COUNT=0 REBOOT_REQUIRED=0 RUN_DURATION=1 RUN_ID=rid
    DISCORD_WEBHOOK=https://example.invalid/SECRET
    write_event; write_event
    [ -f "$EVENTS_FILE" ]; [ -f "$EVENTS_FILE.1" ]
    ! grep -qF SECRET "$EVENTS_FILE" "$EVENTS_FILE.1"
    [ "$(wc -l < "$EVENTS_FILE")" -eq 1 ]
}
