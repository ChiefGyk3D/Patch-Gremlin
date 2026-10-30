#!/usr/bin/env bats
# Harden secret handling: config/secrets files are parsed (never sourced),
# nothing sensitive travels in curl argv, files are created private.

load test_helper

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

run_notifier() {
    run env PATH="$HELPERS:$PATH" \
        STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" \
        PATCH_GREMLIN_SECRETS_FILE="$PATCH_GREMLIN_SECRETS_FILE" \
        PATCH_GREMLIN_CONFIG_FILE="$PATCH_GREMLIN_CONFIG_FILE" \
        PATCH_GREMLIN_ENV_FILE="$SANDBOX/nonexistent-env" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
        PATCH_GREMLIN_OS_TYPE=debian \
        "$@" \
        bash "$REPO_ROOT/update-notifier.sh"
}

# --------------------------------------------------------------------------
# Parsed, not sourced
# --------------------------------------------------------------------------

@test "secrets: values are taken literally and nothing is evaluated" {
    cat > "$PATCH_GREMLIN_SECRETS_FILE" <<EOS
SECRET_MODE="local"
DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/\$(touch $SANDBOX/pwn1)\`touch $SANDBOX/pwn2\`"
touch $SANDBOX/pwn3
\$(touch $SANDBOX/pwn4)
EOS
    chmod 600 "$PATCH_GREMLIN_SECRETS_FILE"
    run_notifier
    [ "$status" -eq 0 ]
    [ ! -e "$SANDBOX/pwn1" ]
    [ ! -e "$SANDBOX/pwn2" ]
    [ ! -e "$SANDBOX/pwn3" ]
    [ ! -e "$SANDBOX/pwn4" ]
    # The literal text reached the sender unchanged.
    grep -qF "\$(touch $SANDBOX/pwn1)" "$STUB_CAPTURE_DIR/call-1"
}

@test "secrets: a config file is parsed, not sourced" {
    cat > "$PATCH_GREMLIN_CONFIG_FILE" <<EOS
touch $SANDBOX/pwn5
export DOPPLER_DISCORD_SECRET="\$(touch $SANDBOX/pwn6)"
EOS
    chmod 600 "$PATCH_GREMLIN_CONFIG_FILE"
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    run_notifier
    [ ! -e "$SANDBOX/pwn5" ]
    [ ! -e "$SANDBOX/pwn6" ]
}

@test "secrets: legacy double-quoted, exported and unquoted lines still load" {
    cat > "$PATCH_GREMLIN_SECRETS_FILE" <<'EOS'
# comment
SECRET_MODE="local"
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/legacy"
NTFY_URL=https://ntfy.example.com
NTFY_TOPIC='servers'
EOS
    chmod 600 "$PATCH_GREMLIN_SECRETS_FILE"
    run_notifier
    [ "$status" -eq 0 ]
    grep -rqF 'webhooks/1/legacy' "$STUB_CAPTURE_DIR"
    grep -rqF 'ntfy.example.com' "$STUB_CAPTURE_DIR"
}

@test "secrets: installer output round-trips hostile values exactly" {
    local nasty='a"b$(touch '"$SANDBOX"'/pwn7)`id`\c$HOME'"'"'q'
    local root="$SANDBOX/root"
    mkdir -p "$root"
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$root" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc \
        LOCAL_NTFY_TOKEN="$nasty" \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -eq 0 ]
    [ ! -e "$SANDBOX/pwn7" ]
    run bash -c "
        export PATCH_GREMLIN_SOURCE_ONLY=1 PATCH_GREMLIN_SECRETS_FILE='$root/etc/update-notifier/secrets.conf'
        export PATCH_GREMLIN_CONFIG_FILE=/nonexistent PATCH_GREMLIN_ENV_FILE=/nonexistent
        source '$REPO_ROOT/update-notifier.sh'
        load_secrets
        printf '%s' \"\$NTFY_TOKEN\""
    [ "$status" -eq 0 ]
    [ "$output" = "$nasty" ]
    [ ! -e "$SANDBOX/pwn7" ]
}

@test "setup: a control character in a secret is rejected" {
    local root="$SANDBOX/root"
    mkdir -p "$root"
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$root" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc \
        LOCAL_NTFY_TOKEN=$'tok\nINJECTED=1' \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -ne 0 ]
    refute grep -qs INJECTED "$root/etc/update-notifier/secrets.conf"
}

# --------------------------------------------------------------------------
# Private from the first byte
# --------------------------------------------------------------------------

@test "setup: write_file creates the file private before any content is written" {
    eval "$(sed -n '/^write_file() {/,/^}/p' "$REPO_ROOT/setup-unattended-upgrades.sh")"
    p() { printf '%s%s' "$SANDBOX" "$1"; }
    # Shadow cat: report the mode of the file as it exists when content lands.
    cat() { local m; m="$(stat -L -c '%a' "/proc/$$/fd/1")"; echo "$m" > "$SANDBOX/mode-at-write"; command cat; }
    umask 022
    write_file /secret.conf 640 <<< "content"
    [ "$(command cat "$SANDBOX/mode-at-write")" = "600" ]
    [ "$(stat -c '%a' "$SANDBOX/secret.conf")" = "640" ]
}

# --------------------------------------------------------------------------
# Nothing sensitive in curl argv
# --------------------------------------------------------------------------

@test "curl: webhook URL and tokens are not in argv" {
    write_secrets '
DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/SEKRETPATH"
NTFY_URL="https://ntfy.example.com"
NTFY_TOPIC="servers"
NTFY_TOKEN="tk_secret"
GOTIFY_URL="https://gotify.example.com/message"
GOTIFY_TOKEN="AtokenX"'
    run_notifier
    [ "$status" -eq 0 ]
    local n=0 f
    for f in "$STUB_CAPTURE_DIR"/call-*; do
        n=$((n + 1))
        grep -E '^(ARGS|CMDLINE)=' "$f" > "$SANDBOX/argv"
        refute grep -qE 'SEKRETPATH|tk_secret|AtokenX|discord.com|ntfy.example|gotify.example' "$SANDBOX/argv"
    done
    [ "$n" -ge 3 ]
    # They still reach curl, through the config file.
    grep -qF 'SEKRETPATH' "$STUB_CAPTURE_DIR"/call-*
    grep -qi 'X-Gotify-Key: AtokenX' "$STUB_CAPTURE_DIR"/call-*
    refute grep -rq 'token=AtokenX' "$STUB_CAPTURE_DIR"
}

@test "curl: the config file is mode 600 and removed on exit" {
    write_secrets 'DISCORD_WEBHOOK="https://discord.com/api/webhooks/1/abc"'
    local tdir="$SANDBOX/tmp"; mkdir -p "$tdir"
    run_notifier TMPDIR="$tdir"
    [ "$status" -eq 0 ]
    grep -q '^CFGMODE=600$' "$STUB_CAPTURE_DIR/call-1"
    [ -z "$(ls -A "$tdir")" ]
}

# --------------------------------------------------------------------------
# Matrix over https only; non-UTF-8 bytes in logs
# --------------------------------------------------------------------------

@test "matrix: a plain-http homeserver is refused before any request" {
    write_secrets '
MATRIX_HOMESERVER="http://matrix.example.org"
MATRIX_USERNAME="bot"
MATRIX_PASSWORD="pw"
MATRIX_ROOM_ID="!room:example.org"'
    run_notifier
    [ -z "$(ls "$STUB_CAPTURE_DIR")" ]
}

@test "log parsing: a non-UTF-8 byte does not hide the upgraded packages" {
    printf '2025-08-20 06:17:19,123 INFO \xff Packages that will be upgraded: libssl3 curl\n' > "$SANDBOX/bin.log"
    LC_ALL=en_US.utf8 run bash -c "
        export PATCH_GREMLIN_SOURCE_ONLY=1
        source '$REPO_ROOT/update-notifier.sh'
        parse_upgraded_packages '$SANDBOX/bin.log' debian"
    [ "$output" = "libssl3 curl" ]
}

# --------------------------------------------------------------------------
# Uninstall touches only its own drop-ins
# --------------------------------------------------------------------------

@test "uninstall: removes only patch-gremlin.conf from the timer drop-in dirs" {
    local root="$SANDBOX/root"
    mkdir -p "$root"
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$root" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN=dp.st.CANARY \
        VERBOSE_LOGGING=false AUTO_REBOOT=true \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -eq 0 ]
    local d="$root/etc/systemd/system/apt-daily-upgrade.timer.d"
    [ -f "$d/patch-gremlin.conf" ]
    echo "[Timer]" > "$d/local-admin.conf"
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$root" \
        PATCH_GREMLIN_OS_TYPE=debian \
        bash "$REPO_ROOT/uninstall.sh" --non-interactive
    [ "$status" -eq 0 ]
    [ ! -e "$d/patch-gremlin.conf" ]
    [ -f "$d/local-admin.conf" ]
}
