#!/usr/bin/env bats
# Doppler mode under the hardened unit and on a manual run (issue #64).
# tests/helpers/doppler is a fake CLI that fails the way the real one does
# when HOME is unwritable and when no token is in its environment.

load test_helper

TOKEN="dp.st.NEVERPRINTME"

setup() {
    setup_sandbox
    ROOTDIR="$SANDBOX/root"
    mkdir -p "$ROOTDIR"
    export ROOTDIR
    # The token sits in the root-only env file only, as the installer writes it.
    ENVFILE="$SANDBOX/env"
    printf 'SECRET_MODE=doppler\nDOPPLER_TOKEN=%s\n' "$TOKEN" > "$ENVFILE"
    chmod 600 "$ENVFILE"
    # A HOME that mkdir cannot create even as root: a path below a regular file.
    : > "$SANDBOX/blocker"
    BAD_HOME="$SANDBOX/blocker/home"
    GOOD_HOME="$SANDBOX/home"
    mkdir -p "$GOOD_HOME"
}
teardown() { teardown_sandbox; }

# Hand run: no DOPPLER_TOKEN in the process environment at all.
run_manual() {
    local home="$1"
    run env -u DOPPLER_TOKEN HOME="$home" PATH="$PATH" \
        STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" \
        PATCH_GREMLIN_ENV_FILE="$ENVFILE" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        PATCH_GREMLIN_SECRETS_FILE="$SANDBOX/absent.conf" \
        PATCH_GREMLIN_CONFIG_FILE="$SANDBOX/absent-config.sh" \
        PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
        PATCH_GREMLIN_OS_TYPE=debian PATCH_GREMLIN_DRY_RUN=true \
        bash "$REPO_ROOT/update-notifier.sh"
}

@test "doppler: manual run reads the token from the env file without exporting it" {
    run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would send notification to"* ]]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
}

@test "doppler: the token never reaches argv or the output" {
    run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-argv" ]
    ! grep -q "$TOKEN" "$STUB_CAPTURE_DIR/doppler-argv"
    [[ "$output" != *"$TOKEN"* ]]
}

@test "doppler: an unwritable HOME fails with the config-directory error (fake CLI bites)" {
    run_manual "$BAD_HOME"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unable to create config directory"* ]]
}

@test "doppler: the fake CLI fails without a token (negative case for the export fix)" {
    run env -u DOPPLER_TOKEN HOME="$GOOD_HOME" PATH="$PATH" doppler me
    [ "$status" -ne 0 ]
    [[ "$output" == *"must provide a token"* ]]
}

@test "doppler: the token is exported to the CLI only, never to other children" {
    load_notifier
    DOPPLER_TOKEN="$TOKEN"   # plain variable, as load_secrets leaves it
    run bash -c 'echo "${DOPPLER_TOKEN:-unset}"'
    [ "$output" = "unset" ]
    HOME="$GOOD_HOME" run doppler_cli me
    [ "$status" -eq 0 ]
    run bash -c 'echo "${DOPPLER_TOKEN:-unset}"'
    [ "$output" = "unset" ]
}

@test "setup: the unit gives the CLI a writable HOME inside ReadWritePaths" {
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN="$TOKEN" VERBOSE_LOGGING=false AUTO_REBOOT=true \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -eq 0 ]
    unit="$ROOTDIR/etc/systemd/system/update-notifier.service"
    grep -qx 'Environment=HOME=/var/lib/patch-gremlin' "$unit"
    grep -q '^ReadWritePaths=/var/lib/patch-gremlin ' "$unit"
    # Hardening is intact and the token is not in the unit.
    grep -qx 'ProtectHome=true' "$unit"
    grep -qx 'ProtectSystem=strict' "$unit"
    ! grep -q "$TOKEN" "$unit"
}

@test "setup: dry-run verification succeeds on a working doppler install" {
    run env PATH="$HELPERS:$PATH" HOME="$GOOD_HOME" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN="$TOKEN" VERBOSE_LOGGING=false AUTO_REBOOT=true \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -eq 0 ]
    [[ "$output" == *"Notification dry-run succeeded"* ]]
    [[ "$output" != *"dry-run failed"* ]]
}

@test "setup: a real verification failure names the cause in one line, with no token" {
    run env PATH="$HELPERS:$PATH" HOME="$BAD_HOME" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN="$TOKEN" VERBOSE_LOGGING=false AUTO_REBOOT=true \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run failed"* ]]
    [[ "$output" == *"Unable to create config directory"* ]]
    [[ "$output" != *"$TOKEN"* ]]
    [ "$(printf '%s\n' "$output" | grep -c 'dry-run failed')" -eq 1 ]
}
