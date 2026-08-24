#!/usr/bin/env bats
# Tests for setup-unattended-upgrades.sh, driven through PATCH_GREMLIN_ROOT
# so a full install is staged into a sandbox instead of the live system.

load test_helper

setup() {
    setup_sandbox
    ROOTDIR="$SANDBOX/root"
    mkdir -p "$ROOTDIR"
    export ROOTDIR
}
teardown() { teardown_sandbox; }

# Force the Debian branch regardless of the host running the suite. Without
# this every apt-path assertion below silently depended on the CI image's
# family, and they all failed on Fedora and Rocky.
install_debian() {
    run env PATH="$HELPERS:$PATH" \
        PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true \
        PATCH_GREMLIN_OS_TYPE=debian \
        "$@" \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
}

install_rhel() {
    run env PATH="$HELPERS:$PATH" \
        PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true \
        PATCH_GREMLIN_OS_TYPE=rhel \
        "$@" \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
}

base_env() {
    echo UPDATE_TYPE=security
    echo UPDATE_SCHEDULE=daily
    echo UPDATE_TIME=02:00
    echo SECRET_MODE=local
    echo VERBOSE_LOGGING=false
    echo AUTO_REBOOT=true
    echo LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
}

default_install() {
    # shellcheck disable=SC2046
    install_debian $(base_env) "$@"
}

# --------------------------------------------------------------------------
# CLI surface
# --------------------------------------------------------------------------

@test "setup: --help works without root" {
    run bash "$REPO_ROOT/setup-unattended-upgrades.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"--non-interactive"* ]]
}

@test "setup: --version works" {
    run bash "$REPO_ROOT/setup-unattended-upgrades.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "setup: unknown option exits 2" {
    run bash "$REPO_ROOT/setup-unattended-upgrades.sh" --bogus
    [ "$status" -eq 2 ]
}

# --------------------------------------------------------------------------
# Regression: weekly preset without UPDATE_DAY
# --------------------------------------------------------------------------

@test "setup: weekly schedule without UPDATE_DAY does not abort" {
    # Used to die with "UPDATE_DAY: unbound variable" mid-install, after the
    # apt config had already been rewritten.
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=weekly UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
    grep -q 'OnCalendar=Sat \*-\*-\* 02:00:00' \
        "$ROOTDIR/etc/systemd/system/apt-daily-upgrade.timer.d/patch-gremlin.conf"
}

@test "setup: weekly schedule honours an explicit UPDATE_DAY" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=weekly UPDATE_DAY=Wed \
        UPDATE_TIME=05:15 SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'OnCalendar=Wed \*-\*-\* 05:15:00' \
        "$ROOTDIR/etc/systemd/system/apt-daily-upgrade.timer.d/patch-gremlin.conf"
}

# --------------------------------------------------------------------------
# Preset validation
# --------------------------------------------------------------------------

@test "setup: rejects a malformed UPDATE_TIME instead of writing it into a unit" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME="25:99" \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"UPDATE_TIME"* ]]
    [ ! -f "$ROOTDIR/etc/systemd/system/apt-daily-upgrade.timer.d/patch-gremlin.conf" ]
}

@test "setup: rejects an injection attempt in UPDATE_TIME" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily \
        UPDATE_TIME='02:00
ExecStart=/bin/evil' \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -ne 0 ]
}

@test "setup: rejects a bad UPDATE_DAY" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=weekly UPDATE_DAY=Funday \
        UPDATE_TIME=02:00 SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"UPDATE_DAY"* ]]
}

@test "setup: rejects a bad UPDATE_TYPE" {
    install_debian UPDATE_TYPE=everything UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"UPDATE_TYPE"* ]]
}

# --------------------------------------------------------------------------
# Non-interactive completeness
# --------------------------------------------------------------------------

@test "setup: local mode with no endpoints fails fast instead of hanging on a prompt" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true
    [ "$status" -ne 0 ]
    [[ "$output" == *"LOCAL_"* ]]
}

@test "setup: doppler mode without a token fails fast" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler VERBOSE_LOGGING=false AUTO_REBOOT=true
    [ "$status" -ne 0 ]
    [[ "$output" == *"DOPPLER_TOKEN"* ]]
}

@test "setup: a full non-interactive local install succeeds" {
    default_install
    [ "$status" -eq 0 ]
    [ -f "$ROOTDIR/usr/local/bin/update-notifier.sh" ]
    [ -f "$ROOTDIR/etc/systemd/system/update-notifier.service" ]
    [ -f "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades" ]
}

# --------------------------------------------------------------------------
# Security
# --------------------------------------------------------------------------

@test "setup: secrets file is mode 600" {
    default_install
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$ROOTDIR/etc/update-notifier/secrets.conf")" = "600" ]
}

@test "setup: doppler token lands in a 600 env file, never in the unit" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN=dp.st.SECRETVALUE \
        VERBOSE_LOGGING=false AUTO_REBOOT=true
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$ROOTDIR/etc/update-notifier/env")" = "600" ]
    grep -q 'DOPPLER_TOKEN=dp.st.SECRETVALUE' "$ROOTDIR/etc/update-notifier/env"
    # The token must not appear in any world-readable file.
    ! grep -rl 'dp.st.SECRETVALUE' "$ROOTDIR/etc/systemd" 2>/dev/null
    ! grep -rl 'dp.st.SECRETVALUE' "$ROOTDIR/etc/apt" 2>/dev/null
}

@test "setup: no world-readable file anywhere contains the token" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN=dp.st.LEAKCANARY \
        VERBOSE_LOGGING=false AUTO_REBOOT=true
    [ "$status" -eq 0 ]
    while IFS= read -r f; do
        mode="$(stat -c '%a' "$f")"
        if [[ "${mode: -1}" =~ [4567] ]] && grep -q 'dp.st.LEAKCANARY' "$f" 2>/dev/null; then
            echo "token leaked into world-readable $f (mode $mode)" >&2
            return 1
        fi
    done < <(find "$ROOTDIR" -type f)
}

@test "setup: config.sh command substitution is refused, not executed" {
    cat > "$SANDBOX/config.sh" <<'EOF'
export DOPPLER_DISCORD_SECRET="$(touch /tmp/pg-pwned-$$)"
export DOPPLER_SLACK_SECRET="LEGIT_NAME"
EOF
    cp "$REPO_ROOT/setup-unattended-upgrades.sh" "$SANDBOX/setup.sh"
    cp "$REPO_ROOT/update-notifier.sh" "$SANDBOX/update-notifier.sh"
    cp "$REPO_ROOT/health-check.sh" "$SANDBOX/health-check.sh"
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_NON_INTERACTIVE=true \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc \
        bash "$SANDBOX/setup.sh" --non-interactive
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell metacharacters"* ]]
    # The legitimate value still loaded.
    [[ "$output" == *"Loaded"* ]]
}

# --------------------------------------------------------------------------
# Generated configuration
# --------------------------------------------------------------------------

@test "setup: reboot time is derived from UPDATE_TIME, not hardcoded 03:00" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=04:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'Automatic-Reboot-Time "05:00"' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

@test "setup: reboot time wraps past midnight" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=23:30 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'Automatic-Reboot-Time "00:30"' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

@test "setup: Automatic-Reboot-WithUsers defaults to false" {
    default_install
    [ "$status" -eq 0 ]
    grep -q 'Automatic-Reboot-WithUsers "false"' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

@test "setup: security-only mode includes Ubuntu ESM origins" {
    default_install
    [ "$status" -eq 0 ]
    grep -q 'UbuntuESMApps' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    grep -q 'UbuntuESM,' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

@test "setup: security-only mode excludes non-security origins" {
    default_install
    [ "$status" -eq 0 ]
    ! grep -q 'archive=${distro_codename}-updates' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

@test "setup: 'all' mode includes the updates origins" {
    install_debian UPDATE_TYPE=all UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'archive=${distro_codename}-updates' "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
}

# --------------------------------------------------------------------------
# Units and hooks
# --------------------------------------------------------------------------

@test "setup: notification hangs off the upgrade unit, not a racing timer" {
    default_install
    [ "$status" -eq 0 ]
    grep -q 'ExecStartPost=-/usr/local/bin/update-notifier.sh' \
        "$ROOTDIR/etc/systemd/system/apt-daily-upgrade.service.d/patch-gremlin.conf"
}

@test "setup: writes no Dpkg::Post-Invoke hook" {
    # The v1 hook fired after EVERY dpkg invocation, so `apt install htop`
    # sent a notification, and it ran apt inside an in-progress transaction.
    default_install
    [ "$status" -eq 0 ]
    [ ! -f "$ROOTDIR/etc/apt/apt.conf.d/99patch-gremlin-notification" ]
}

@test "setup: removes a legacy v1 APT hook on upgrade" {
    mkdir -p "$ROOTDIR/etc/apt/apt.conf.d"
    echo 'Dpkg::Post-Invoke { "... DOPPLER_TOKEN=dp.st.old ..."; };' \
        > "$ROOTDIR/etc/apt/apt.conf.d/99patch-gremlin-notification"
    default_install
    [ "$status" -eq 0 ]
    [ ! -f "$ROOTDIR/etc/apt/apt.conf.d/99patch-gremlin-notification" ]
    [[ "$output" == *"legacy APT"* ]]
}

@test "setup: timer has no Requires= in [Unit]" {
    # Requires= there makes systemd start the service the moment the timer
    # starts, firing a notification on every boot.
    default_install
    [ "$status" -eq 0 ]
    ! grep -q '^Requires=' "$ROOTDIR/etc/systemd/system/update-notifier.timer"
    grep -q '^Unit=update-notifier.service' "$ROOTDIR/etc/systemd/system/update-notifier.timer"
}

@test "setup: heartbeat timer is disabled by default" {
    default_install
    [ "$status" -eq 0 ]
    grep -q 'systemctl disable update-notifier.timer' "$ROOTDIR/systemctl.log"
}

@test "setup: heartbeat timer can be enabled and is offset from the upgrade window" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true ENABLE_HEARTBEAT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'OnCalendar=\*-\*-\* 04:00:00' "$ROOTDIR/etc/systemd/system/update-notifier.timer"
    grep -q 'systemctl enable --now update-notifier.timer' "$ROOTDIR/systemctl.log"
}

@test "setup: service uses EnvironmentFile and is hardened" {
    default_install
    [ "$status" -eq 0 ]
    grep -q 'EnvironmentFile=/etc/update-notifier/env' "$ROOTDIR/etc/systemd/system/update-notifier.service"
    grep -q 'NoNewPrivileges=true' "$ROOTDIR/etc/systemd/system/update-notifier.service"
    grep -q 'ProtectSystem=strict' "$ROOTDIR/etc/systemd/system/update-notifier.service"
    ! grep -q 'WantedBy=multi-user.target' "$ROOTDIR/etc/systemd/system/update-notifier.service"
}

# --------------------------------------------------------------------------
# Installed artefacts
# --------------------------------------------------------------------------

@test "setup: installs the health-check script the monitoring hooks expect" {
    default_install
    [ "$status" -eq 0 ]
    [ -x "$ROOTDIR/usr/local/bin/patch-gremlin-health-check.sh" ]
}

@test "setup: backups go to /var/backups, not into apt.conf.d" {
    mkdir -p "$ROOTDIR/etc/apt/apt.conf.d"
    echo "// pre-existing" > "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades"
    default_install
    [ "$status" -eq 0 ]
    ls "$ROOTDIR/var/backups/patch-gremlin/" | grep -q '50unattended-upgrades'
    ! ls "$ROOTDIR/etc/apt/apt.conf.d/" | grep -q 'backup'
}

@test "setup: relocates stray v1 backups out of apt.conf.d" {
    mkdir -p "$ROOTDIR/etc/apt/apt.conf.d"
    echo "// old" > "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades.backup.20240101-000000"
    default_install
    [ "$status" -eq 0 ]
    ! ls "$ROOTDIR/etc/apt/apt.conf.d/" | grep -q 'backup'
}

@test "setup: timezone preset is actually applied" {
    # SYSTEM_TIMEZONE was documented but the preset path was a silent no-op.
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        SYSTEM_TIMEZONE=America/New_York \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'America/New_York' "$ROOTDIR/etc/timezone"
}

@test "setup: rejects a bogus timezone" {
    install_debian UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        SYSTEM_TIMEZONE='../../etc/passwd' \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -ne 0 ]
}

@test "setup: --update-only refreshes scripts without touching config" {
    default_install
    [ "$status" -eq 0 ]
    echo "SENTINEL" >> "$ROOTDIR/etc/update-notifier/secrets.conf"
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --update-only
    [ "$status" -eq 0 ]
    grep -q SENTINEL "$ROOTDIR/etc/update-notifier/secrets.conf"
    [ -x "$ROOTDIR/usr/local/bin/update-notifier.sh" ]
}

@test "setup: install is idempotent" {
    default_install
    [ "$status" -eq 0 ]
    first="$(cat "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades")"
    default_install
    [ "$status" -eq 0 ]
    second="$(cat "$ROOTDIR/etc/apt/apt.conf.d/50unattended-upgrades")"
    [ "$first" = "$second" ]
}

# --------------------------------------------------------------------------
# RHEL branch - previously untested, and the reason the Fedora/Rocky CI jobs
# were only ever exercising half the installer.
# --------------------------------------------------------------------------

rhel_env() {
    echo UPDATE_TYPE=security
    echo UPDATE_SCHEDULE=daily
    echo UPDATE_TIME=02:00
    echo SECRET_MODE=local
    echo VERBOSE_LOGGING=false
    echo AUTO_REBOOT=true
    echo LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
}

default_rhel_install() {
    # shellcheck disable=SC2046
    install_rhel $(rhel_env) "$@"
}

@test "setup(rhel): a full non-interactive install succeeds" {
    default_rhel_install
    [ "$status" -eq 0 ]
    [ -f "$ROOTDIR/etc/dnf/automatic.conf" ]
    [ -f "$ROOTDIR/usr/local/bin/update-notifier.sh" ]
    [ -f "$ROOTDIR/usr/local/bin/patch-gremlin-health-check.sh" ]
    [ -f "$ROOTDIR/etc/systemd/system/update-notifier.service" ]
    # No apt artefacts on the RHEL branch
    [ ! -e "$ROOTDIR/etc/apt" ]
}

@test "setup(rhel): security mode sets upgrade_type = security" {
    default_rhel_install
    [ "$status" -eq 0 ]
    grep -q '^upgrade_type = security' "$ROOTDIR/etc/dnf/automatic.conf"
}

@test "setup(rhel): 'all' mode sets upgrade_type = default" {
    install_rhel UPDATE_TYPE=all UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q '^upgrade_type = default' "$ROOTDIR/etc/dnf/automatic.conf"
}

@test "setup(rhel): auto-reboot maps onto dnf-automatic's reboot setting" {
    default_rhel_install
    [ "$status" -eq 0 ]
    grep -q '^reboot = when-needed' "$ROOTDIR/etc/dnf/automatic.conf"

    install_rhel UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=false \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q '^reboot = never' "$ROOTDIR/etc/dnf/automatic.conf"
}

@test "setup(rhel): notification hangs off dnf-automatic.service" {
    default_rhel_install
    [ "$status" -eq 0 ]
    grep -q 'ExecStartPost=-/usr/local/bin/update-notifier.sh' \
        "$ROOTDIR/etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf"
    # and the token is NOT exported into the upgrade process.
    # Anchor the match: the file carries a comment explaining the absence.
    ! grep -q '^EnvironmentFile=' \
        "$ROOTDIR/etc/systemd/system/dnf-automatic.service.d/patch-gremlin.conf"
}

@test "setup(rhel): weekly schedule lands in the dnf-automatic timer override" {
    install_rhel UPDATE_TYPE=security UPDATE_SCHEDULE=weekly UPDATE_DAY=Tue \
        UPDATE_TIME=04:45 SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc
    [ "$status" -eq 0 ]
    grep -q 'OnCalendar=Tue \*-\*-\* 04:45:00' \
        "$ROOTDIR/etc/systemd/system/dnf-automatic.timer.d/patch-gremlin.conf"
}

@test "setup(rhel): secrets file is mode 600 and holds no token in the unit" {
    install_rhel UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=doppler DOPPLER_TOKEN=dp.st.RHELCANARY \
        VERBOSE_LOGGING=false AUTO_REBOOT=true
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$ROOTDIR/etc/update-notifier/env")" = "600" ]
    while IFS= read -r f; do
        mode="$(stat -c '%a' "$f")"
        if [[ "${mode: -1}" =~ [4567] ]] && grep -q 'dp.st.RHELCANARY' "$f" 2>/dev/null; then
            echo "token leaked into world-readable $f (mode $mode)" >&2
            return 1
        fi
    done < <(find "$ROOTDIR" -type f)
}

@test "setup(rhel): install is idempotent" {
    default_rhel_install
    [ "$status" -eq 0 ]
    first="$(cat "$ROOTDIR/etc/dnf/automatic.conf")"
    default_rhel_install
    [ "$status" -eq 0 ]
    [ "$first" = "$(cat "$ROOTDIR/etc/dnf/automatic.conf")" ]
}

@test "setup: an invalid PATCH_GREMLIN_OS_TYPE is rejected" {
    run env PATH="$HELPERS:$PATH" PATCH_GREMLIN_ROOT="$ROOTDIR" \
        PATCH_GREMLIN_OS_TYPE=plan9 \
        UPDATE_TYPE=security UPDATE_SCHEDULE=daily UPDATE_TIME=02:00 \
        SECRET_MODE=local VERBOSE_LOGGING=false AUTO_REBOOT=true \
        LOCAL_DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc \
        bash "$REPO_ROOT/setup-unattended-upgrades.sh" --non-interactive
    [ "$status" -ne 0 ]
    [[ "$output" == *"PATCH_GREMLIN_OS_TYPE"* ]]
}
