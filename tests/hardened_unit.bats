#!/usr/bin/env bats
# Doppler mode under the hardened unit and on a manual run (issue #64).
# tests/helpers/doppler is a fake CLI that fails the way the real one does
# when HOME is unwritable and when no token is in its environment.
# tests/helpers/curl records whether it inherited DOPPLER_TOKEN.

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
    # The CLI home as the installer makes it: a private directory.
    GOOD_HOME="$SANDBOX/home"
    mkdir -p "$GOOD_HOME"
    chmod 700 "$GOOD_HOME"
}
teardown() { teardown_sandbox; }

# Notifier run with no DOPPLER_TOKEN in the process environment (hand run).
# Set DRY=false to let it reach the (fake) curl.
run_manual() {
    local home="$1"
    run env -u DOPPLER_TOKEN HOME="$home" PATH="$PATH" \
        STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" \
        PATCH_GREMLIN_ENV_FILE="$ENVFILE" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        PATCH_GREMLIN_SECRETS_FILE="$SANDBOX/absent.conf" \
        PATCH_GREMLIN_CONFIG_FILE="$SANDBOX/absent-config.sh" \
        PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
        PATCH_GREMLIN_OS_TYPE=debian PATCH_GREMLIN_DRY_RUN="${DRY:-true}" \
        SHELLOPTS="${PG_TEST_SHELLOPTS:-}" \
        bash ${PG_TEST_BASHFLAGS:-} "$REPO_ROOT/update-notifier.sh"
}

# Service run: systemd's EnvironmentFile= exports the token before the start.
run_unit() {
    run env DOPPLER_TOKEN="$TOKEN" HOME="$GOOD_HOME" PATH="$PATH" \
        STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" \
        PATCH_GREMLIN_ENV_FILE="$ENVFILE" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        PATCH_GREMLIN_SECRETS_FILE="$SANDBOX/absent.conf" \
        PATCH_GREMLIN_CONFIG_FILE="$SANDBOX/absent-config.sh" \
        PATCH_GREMLIN_LOG_FILE="$FIXTURES/uu-upgraded.log" \
        PATCH_GREMLIN_OS_TYPE=debian PATCH_GREMLIN_DRY_RUN=false \
        bash "$REPO_ROOT/update-notifier.sh"
}

full_setup() {
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN="$TOKEN" VERBOSE_LOGGING=false AUTO_REBOOT=true \
        "$@" \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
}

# --------------------------------------------------------------------------
# Notifier: token handling
# --------------------------------------------------------------------------

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

@test "doppler: the fake CLI fails on an unwritable HOME and without a token" {
    run env -u DOPPLER_TOKEN HOME="$BAD_HOME" PATH="$PATH" doppler me
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unable to create config directory"* ]]
    run env -u DOPPLER_TOKEN HOME="$GOOD_HOME" PATH="$PATH" doppler me
    [ "$status" -ne 0 ]
    [[ "$output" == *"must provide a token"* ]]
}

@test "doppler: manual path - a child such as curl does not inherit the token" {
    DRY=false run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
    grep -q '^ENV_HAS_TOKEN=no$' "$STUB_CAPTURE_DIR/call-1"
    ! grep -rq "$TOKEN" "$STUB_CAPTURE_DIR"
}

@test "doppler: unit path - the exported token reaches the CLI but not curl" {
    run_unit
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
    [ -e "$STUB_CAPTURE_DIR/call-1" ]
    grep -q '^ENV_HAS_TOKEN=no$' "$STUB_CAPTURE_DIR/call-1"
    ! grep -rq "$TOKEN" "$STUB_CAPTURE_DIR"
}

@test "doppler: the fake curl does report an inherited token (negative case)" {
    run env DOPPLER_TOKEN="$TOKEN" STUB_CAPTURE_DIR="$STUB_CAPTURE_DIR" PATH="$PATH" \
        curl -s https://example.org/x
    grep -q '^ENV_HAS_TOKEN=yes$' "$STUB_CAPTURE_DIR/call-1"
}

# --------------------------------------------------------------------------
# Notifier: CLI home checks
# --------------------------------------------------------------------------

@test "doppler: a symlinked HOME is refused and the CLI never runs" {
    mkdir -p "$SANDBOX/real"; chmod 700 "$SANDBOX/real"
    ln -s "$SANDBOX/real" "$SANDBOX/link"
    run_manual "$SANDBOX/link"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run the Doppler CLI"* ]]
    [ ! -e "$STUB_CAPTURE_DIR/doppler-argv" ]
}

@test "doppler: a HOME that is not a directory is refused" {
    run_manual "$SANDBOX/blocker"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run the Doppler CLI"* ]]
    [ ! -e "$STUB_CAPTURE_DIR/doppler-argv" ]
}

@test "doppler: a HOME open to other users is refused" {
    chmod 755 "$GOOD_HOME"
    run_manual "$GOOD_HOME"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run the Doppler CLI"* ]]
    [ ! -e "$STUB_CAPTURE_DIR/doppler-argv" ]
    # Any group or other access is refused, not just writable modes.
    for m in 770 750 710 550 701; do
        chmod "$m" "$GOOD_HOME"
        run_manual "$GOOD_HOME"
        [ "$status" -ne 0 ]
        [ ! -e "$STUB_CAPTURE_DIR/doppler-argv" ]
    done
}

@test "doppler: an unsafe HOME falls back to the private home below the state dir, nothing else" {
    chmod 755 "$GOOD_HOME"
    mkdir -p "$PATCH_GREMLIN_STATE_DIR/home"
    chmod 700 "$PATCH_GREMLIN_STATE_DIR/home"
    run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
    # A fallback that is itself open is refused too.
    rm -f "$STUB_CAPTURE_DIR/doppler-env" "$STUB_CAPTURE_DIR/doppler-argv"
    chmod 755 "$PATCH_GREMLIN_STATE_DIR/home"
    run_manual "$GOOD_HOME"
    [ "$status" -ne 0 ]
    [ ! -e "$STUB_CAPTURE_DIR/doppler-argv" ]
}

@test "doppler: an inherited allexport does not re-export the token to curl" {
    PG_TEST_SHELLOPTS=allexport DRY=false run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
    grep -q '^ENV_HAS_TOKEN=no$' "$STUB_CAPTURE_DIR/call-1"
}

@test "doppler: bash -x tracing never prints the token" {
    PG_TEST_BASHFLAGS=-x DRY=false run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
    [[ "$output" == *"+ "* ]]
    [[ "$output" != *"$TOKEN"* ]]
}

@test "doppler: a HOME owned by someone else is refused" {
    if [ "$(id -u)" -ne 0 ]; then skip "needs root to chown"; fi
    chown 65534 "$GOOD_HOME"
    run_manual "$GOOD_HOME"
    [ "$status" -ne 0 ]
    [ ! -e "$STUB_CAPTURE_DIR/doppler-argv" ]
}

@test "doppler: CLI error text is classified, never echoed (no token, URL or control bytes)" {
    export STUB_DOPPLER_MSG='invalid token: dp.st.LEAKED webhook=https://example.invalid/secret \r\\c'
    run_manual "$GOOD_HOME"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Doppler said: the service token is missing, invalid or was rejected"* ]]
    [[ "$output" != *"LEAKED"* ]]
    [[ "$output" != *"example.invalid"* ]]
    [[ "$output" != *$'\r'* ]]
}

@test "doppler: env file with CRLF, spaces and quotes reads like systemd" {
    printf 'SECRET_MODE=doppler\r\n  DOPPLER_TOKEN="%s"  \r\n' "$TOKEN" > "$ENVFILE"
    run_manual "$GOOD_HOME"
    [ "$status" -eq 0 ]
    [ -s "$STUB_CAPTURE_DIR/doppler-env" ]
}

# --------------------------------------------------------------------------
# Setup: unit, CLI home, upgrade path
# --------------------------------------------------------------------------

@test "setup: the unit points HOME at a private CLI home inside ReadWritePaths" {
    full_setup
    [ "$status" -eq 0 ]
    unit="$ROOTDIR/etc/systemd/system/update-notifier.service"
    grep -qx 'Environment=HOME=/var/lib/patch-gremlin/home' "$unit"
    grep -q '^ReadWritePaths=/var/lib/patch-gremlin ' "$unit"
    grep -qx 'ProtectHome=true' "$unit"
    grep -qx 'ProtectSystem=strict' "$unit"
    ! grep -q "$TOKEN" "$unit"
    home="$ROOTDIR/var/lib/patch-gremlin/home"
    [ -d "$home" ] && [ ! -L "$home" ]
    [ "$(stat -c '%a' "$home")" = "700" ]
    # The state directory the monitoring readers use is left as it was.
    [ $(( 8#$(stat -c '%a' "$ROOTDIR/var/lib/patch-gremlin") & 5 )) -eq 5 ]
}

@test "setup: a re-run repairs the CLI home mode and stays idempotent" {
    full_setup
    [ "$status" -eq 0 ]
    chmod 755 "$ROOTDIR/var/lib/patch-gremlin/home"
    full_setup
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$ROOTDIR/var/lib/patch-gremlin/home")" = "700" ]
}

@test "setup: a symlinked CLI home is refused" {
    mkdir -p "$ROOTDIR/var/lib/patch-gremlin" "$SANDBOX/elsewhere"
    ln -s "$SANDBOX/elsewhere" "$ROOTDIR/var/lib/patch-gremlin/home"
    full_setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
}

@test "setup: the hand-made HOME drop-in is removed cleanly and a re-run is idempotent" {
    dir="$ROOTDIR/etc/systemd/system/update-notifier.service.d"
    mkdir -p "$dir"
    printf '[Service]\nEnvironment=HOME=/var/lib/patch-gremlin\n' > "$dir/override.conf"
    printf '[Service]\nEnvironment=HOME=/var/lib/patch-gremlin\nEnvironment=FOO=bar\n' > "$dir/other.conf"
    full_setup
    [ "$status" -eq 0 ]
    [ ! -e "$dir/override.conf" ]
    grep -qx 'Environment=FOO=bar' "$dir/other.conf"
    ! grep -q 'HOME=' "$dir/other.conf"
    full_setup
    [ "$status" -eq 0 ]
    grep -qx 'Environment=FOO=bar' "$dir/other.conf"
}

@test "setup: drop-in migration keeps a private file's mode (600 stays 600)" {
    dir="$ROOTDIR/etc/systemd/system/update-notifier.service.d"
    mkdir -p "$dir"
    printf '[Service]\nEnvironment=HOME=/var/lib/patch-gremlin\nEnvironment=PRIVATE=1\n' > "$dir/private.conf"
    chmod 600 "$dir/private.conf"
    full_setup
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$dir/private.conf")" = "600" ]
    grep -qx 'Environment=PRIVATE=1' "$dir/private.conf"
    ! grep -q 'HOME=' "$dir/private.conf"
}

@test "setup: drop-in migration catches quoted, spaced and slashed forms, keeps other settings" {
    dir="$ROOTDIR/etc/systemd/system/update-notifier.service.d"
    mkdir -p "$dir"
    printf '[Service]\nEnvironment="HOME=/var/lib/patch-gremlin"\n' > "$dir/a.conf"
    printf '[Service]\nEnvironment = HOME=/var/lib/patch-gremlin\n' > "$dir/b.conf"
    printf '[Service]\nEnvironment=HOME=/var/lib/patch-gremlin/\n' > "$dir/c.conf"
    printf '[Service]\nEnvironment="HOME=/var/lib/patch-gremlin" FOO=bar\n' > "$dir/d.conf"
    printf "[Service]\nEnvironment='HOME=/var/lib/patch-gremlin' \"BAZ=a b\"\n" > "$dir/e.conf"
    printf '[Service]\nEnvironment=HOME=/somewhere/else\n' > "$dir/f.conf"
    full_setup
    [ "$status" -eq 0 ]
    [ ! -e "$dir/a.conf" ]
    [ ! -e "$dir/b.conf" ]
    [ ! -e "$dir/c.conf" ]
    grep -qx 'Environment=FOO=bar' "$dir/d.conf"
    grep -qx 'Environment="BAZ=a b"' "$dir/e.conf"
    # An unrelated HOME is not ours to remove.
    grep -qx 'Environment=HOME=/somewhere/else' "$dir/f.conf"
}

@test "setup: --update-only moves an old unit to the new HOME, idempotently" {
    full_setup
    [ "$status" -eq 0 ]
    unit="$ROOTDIR/etc/systemd/system/update-notifier.service"
    sed -i '/^Environment=HOME=/d' "$unit"
    ! grep -q '^Environment=HOME=' "$unit"
    for _ in 1 2; do
        run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
            bash "$REPO_ROOT/setup-unattended-upgrades.sh" --update-only
        [ "$status" -eq 0 ]
        [ "$(grep -c '^Environment=HOME=/var/lib/patch-gremlin/home$' "$unit")" -eq 1 ]
    done
    grep -qx 'ProtectHome=true' "$unit"
    [ -d "$ROOTDIR/var/lib/patch-gremlin/home" ]
}

# --------------------------------------------------------------------------
# Setup: verification
# --------------------------------------------------------------------------

@test "setup: dry-run verification succeeds on a working install, whatever HOME the caller has" {
    full_setup HOME="$BAD_HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Notification dry-run succeeded"* ]]
    [[ "$output" != *"dry-run failed"* ]]
}

@test "setup: a real verification failure names the cause in one line, with no token" {
    full_setup STUB_DOPPLER_MSG="Doppler Error: Unable to create config directory /x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run failed"* ]]
    [[ "$output" == *"Unable to create config directory"* ]]
    [[ "$output" != *"$TOKEN"* ]]
    [ "$(printf '%s\n' "$output" | grep -c 'dry-run failed')" -eq 1 ]
}

@test "setup: verification output carries no CLI text, token, URL or control bytes" {
    full_setup STUB_DOPPLER_MSG='invalid token: dp.st.LEAKED https://example.invalid/secret \r \\c'
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run failed"* ]]
    [[ "$output" != *"LEAKED"* ]]
    [[ "$output" != *"example.invalid"* ]]
    [[ "$output" != *$'\r'* ]]
}
