#!/usr/bin/env bats
# Install -> configure -> uninstall round trips.

load test_helper

setup() {
    setup_sandbox
    ROOTDIR="$SANDBOX/root"
    mkdir -p "$ROOTDIR"
    export ROOTDIR
}
teardown() { teardown_sandbox; }

# Debian branch: these tests assert on apt configuration, so the family must
# be forced rather than inherited from the host.
full_install() {
    run env PATH="$HELPERS:$PATH" \
        PATCH_GREMLIN_ROOT="$ROOTDIR" PATCH_GREMLIN_NON_INTERACTIVE=true \
        PATCH_GREMLIN_OS_TYPE=debian \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN=dp.st.CANARY \
        VERBOSE_LOGGING=false AUTO_REBOOT=true \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -eq 0 ]
}

uninstall() {
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_OS_TYPE=debian \
        bash "$REPO_ROOT/uninstall.sh" --non-interactive "$@"
}

# --------------------------------------------------------------------------
# uninstall.sh
# --------------------------------------------------------------------------

@test "uninstall: refuses to run as a non-root user" {
    # Every other privileged script checked this; the uninstaller did not, so
    # it half-ran with each rm failing silently.
    if ! command -v setpriv >/dev/null 2>&1 || [ "$(id -u)" -ne 0 ]; then
        skip "needs root + setpriv to drop privileges"
    fi
    run setpriv --reuid=65534 --regid=65534 --clear-groups \
        bash "$REPO_ROOT/uninstall.sh" --non-interactive
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be run as root"* ]]
}

@test "uninstall: --help works" {
    run bash "$REPO_ROOT/uninstall.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "uninstall: removes every artefact the installer created" {
    full_install
    uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTDIR/usr/local/bin/update-notifier.sh" ]
    [ ! -e "$ROOTDIR/usr/local/bin/patch-gremlin-health-check.sh" ]
    [ ! -e "$ROOTDIR/etc/systemd/system/update-notifier.service" ]
    [ ! -e "$ROOTDIR/etc/systemd/system/update-notifier.timer" ]
    [ ! -e "$ROOTDIR/etc/systemd/system/apt-daily-upgrade.service.d/patch-gremlin.conf" ]
    [ ! -e "$ROOTDIR/etc/update-notifier" ]
    [ ! -e "$ROOTDIR/var/lib/patch-gremlin" ]
}

@test "uninstall: leaves no trace of the Doppler token" {
    full_install
    uninstall
    [ "$status" -eq 0 ]
    ! grep -rq 'dp.st.CANARY' "$ROOTDIR" 2>/dev/null
}

@test "uninstall: keeps automatic updates enabled by default" {
    full_install
    uninstall
    [ "$status" -eq 0 ]
    grep -q 'systemctl enable apt-daily-upgrade.timer' "$ROOTDIR/systemctl.log"
    [[ "$output" != *"no longer receive"* ]]
}

@test "uninstall: --all disables the update system and says so" {
    full_install
    uninstall --all
    [ "$status" -eq 0 ]
    grep -q 'systemctl disable apt-daily-upgrade.timer' "$ROOTDIR/systemctl.log"
    [[ "$output" == *"automatic updates are now disabled"* ]]
}

@test "uninstall: restores the pre-install config from backups" {
    mkdir -p "$ROOTDIR/etc/apt/apt.conf.d"
    echo "// ORIGINAL CONFIG" > "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    full_install
    # Installer overwrote it
    ! grep -q "ORIGINAL CONFIG" "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    uninstall
    [ "$status" -eq 0 ]
    grep -q "ORIGINAL CONFIG" "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

@test "uninstall: keeps backups unless --purge-backups is given" {
    mkdir -p "$ROOTDIR/etc/apt/apt.conf.d"
    echo "// ORIGINAL" > "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    full_install
    uninstall
    [ -d "$ROOTDIR/var/backups/patch-gremlin" ]
    uninstall --purge-backups
    [ ! -d "$ROOTDIR/var/backups/patch-gremlin" ]
}

@test "uninstall: is safe to run twice" {
    full_install
    uninstall
    [ "$status" -eq 0 ]
    uninstall
    [ "$status" -eq 0 ]
}

@test "uninstall: removes a legacy v1 APT hook too" {
    mkdir -p "$ROOTDIR/etc/apt/apt.conf.d"
    echo 'Dpkg::Post-Invoke { "..."; };' > "$ROOTDIR/etc/apt/apt.conf.d/99patch-gremlin-notification"
    uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTDIR/etc/apt/apt.conf.d/99patch-gremlin-notification" ]
}

# --------------------------------------------------------------------------
# configure-verbosity.sh
# --------------------------------------------------------------------------

verbosity() {
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_OS_TYPE=debian \
        bash "$REPO_ROOT/configure-verbosity.sh" "$@"
}

@test "verbosity: --verbose then --quiet round trips" {
    full_install
    verbosity --verbose
    [ "$status" -eq 0 ]
    grep -q 'Unattended-Upgrade::Verbose "true"' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    grep -q 'APT::Periodic::Verbose "2"' "$ROOTDIR/etc/apt/apt.conf.d/20auto-upgrades"

    verbosity --quiet
    [ "$status" -eq 0 ]
    grep -q 'Unattended-Upgrade::Verbose "false"' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    grep -q 'APT::Periodic::Verbose "0"' "$ROOTDIR/etc/apt/apt.conf.d/20auto-upgrades"
}

@test "verbosity: does not duplicate the directive on repeated runs" {
    full_install
    verbosity --verbose
    verbosity --verbose
    verbosity --quiet
    [ "$status" -eq 0 ]
    count=$(grep -c 'Unattended-Upgrade::Verbose' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades")
    [ "$count" -eq 1 ]
}

@test "verbosity: backups land outside apt.conf.d" {
    full_install
    verbosity --verbose
    [ "$status" -eq 0 ]
    ! ls "$ROOTDIR/etc/apt/apt.conf.d/" | grep -q backup
    ls "$ROOTDIR/var/backups/patch-gremlin/" | grep -q '50unattended-upgrades'
}

@test "verbosity: --show reports without modifying anything" {
    full_install
    before="$(cat "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades")"
    verbosity --show
    [ "$status" -eq 0 ]
    [[ "$output" == *"Current verbose logging status"* ]]
    [ "$before" = "$(cat "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades")" ]
}

@test "verbosity: fails cleanly with no TTY and no flag" {
    full_install
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_OS_TYPE=debian \
        bash "$REPO_ROOT/configure-verbosity.sh" < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"--quiet"* ]]
}

@test "verbosity: fix-verbose-now.sh still works as a shim" {
    full_install
    verbosity --verbose
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_OS_TYPE=debian \
        bash "$REPO_ROOT/fix-verbose-now.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deprecated"* ]]
    grep -q 'Unattended-Upgrade::Verbose "false"' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}
