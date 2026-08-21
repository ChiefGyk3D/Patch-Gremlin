#!/usr/bin/env bats
# Tests for health-check.sh and the monitoring integrations.

load test_helper

setup() {
    setup_sandbox
    FAKEBIN="$SANDBOX/bin"
    mkdir -p "$FAKEBIN"
    export FAKEBIN
    # systemctl stub driven by STUB_ACTIVE / STUB_ENABLED / STUB_KNOWN
    cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
  is-active)      [[ "${STUB_ACTIVE:-yes}" == "yes" ]] && exit 0 || exit 3 ;;
  is-enabled)     [[ "${STUB_ENABLED:-yes}" == "yes" ]] && exit 0 || exit 1 ;;
  list-unit-files) [[ "${STUB_KNOWN:-yes}" == "yes" ]] && exit 0 || exit 1 ;;
  show)           echo "Environment=SECRET_MODE=local" ;;
esac
exit 0
EOF
    chmod +x "$FAKEBIN/systemctl"
    export PATH="$FAKEBIN:$PATH"
}
teardown() { teardown_sandbox; }

# --------------------------------------------------------------------------
# health-check.sh
# --------------------------------------------------------------------------

hc() {
    run env PATH="$FAKEBIN:$HELPERS:$PATH" \
        PATCH_GREMLIN_NOTIFIER="$1" \
        PATCH_GREMLIN_SERVICE_DIR="$SANDBOX/systemd" \
        "${@:2}" \
        bash "$REPO_ROOT/health-check.sh"
}

install_fake_install() {
    mkdir -p "$SANDBOX/systemd" "$SANDBOX/bin"
    touch "$SANDBOX/systemd/update-notifier.service" \
          "$SANDBOX/systemd/update-notifier.timer"
    cat > "$SANDBOX/bin/notifier" <<EOF
#!/bin/bash
exit ${1:-0}
EOF
    chmod +x "$SANDBOX/bin/notifier"
}

@test "health-check: reports HEALTHY and exits 0 on a good install" {
    install_fake_install 0
    hc "$SANDBOX/bin/notifier"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HEALTHY"* ]]
}

@test "health-check: does not abort on the first error - prints a summary" {
    # Regression: ((ERRORS++)) returns 1 when the counter goes 0->1, which
    # under `set -e` killed the script before it printed anything.
    hc "$SANDBOX/bin/missing-notifier"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Health Check Summary"* ]]
    [[ "$output" == *"CRITICAL"* ]]
}

@test "health-check: counts every missing file, not just the first" {
    hc "$SANDBOX/bin/missing-notifier"
    [ "$status" -eq 2 ]
    # notifier + service + timer = at least 3 errors
    errors=$(echo "$output" | sed -n 's/.*Errors: \([0-9]*\).*/\1/p' | tail -1)
    [ "$errors" -ge 3 ]
}

@test "health-check: inactive timer is a WARNING (exit 1), not CRITICAL" {
    install_fake_install 0
    hc "$SANDBOX/bin/notifier" STUB_ACTIVE=no STUB_KNOWN=yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING"* ]]
}

@test "health-check: a failing notifier dry-run is CRITICAL" {
    install_fake_install
    cat > "$SANDBOX/bin/notifier" <<'EOF'
#!/bin/bash
echo "boom" >&2
exit 1
EOF
    chmod +x "$SANDBOX/bin/notifier"
    hc "$SANDBOX/bin/notifier"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CRITICAL"* ]]
}

@test "health-check: --help works" {
    run bash "$REPO_ROOT/health-check.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

# --------------------------------------------------------------------------
# monitoring/nagios-check.sh
# --------------------------------------------------------------------------

nagios() {
    run env PATH="$FAKEBIN:$HELPERS:$PATH" \
        PATCH_GREMLIN_HEALTH_SCRIPT="$SANDBOX/bin/health" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        bash "$REPO_ROOT/monitoring/nagios-check.sh"
}

fake_health() {
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/health" <<EOF
#!/bin/bash
echo "health output"
exit $1
EOF
    chmod +x "$SANDBOX/bin/health"
}

fresh_state() {
    mkdir -p "$PATCH_GREMLIN_STATE_DIR"
    cat > "$PATCH_GREMLIN_STATE_DIR/state" <<EOF
last_run_epoch=$(date +%s)
last_status=no-updates
notification_sent=true
EOF
}

@test "nagios: propagates WARNING (exit 1) from the health script" {
    # Regression: \$? inside `if ! cmd; then` is the status of the negation
    # (always 0), so this check could only ever report UNKNOWN.
    fake_health 1
    fresh_state
    nagios
    [ "$status" -eq 1 ]
    [[ "$output" == WARNING* ]]
}

@test "nagios: propagates CRITICAL (exit 2) from the health script" {
    fake_health 2
    fresh_state
    nagios
    [ "$status" -eq 2 ]
    [[ "$output" == CRITICAL* ]]
}

@test "nagios: reports OK when healthy and recently run" {
    fake_health 0
    fresh_state
    nagios
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "nagios: warns when the last run is too old" {
    fake_health 0
    mkdir -p "$PATCH_GREMLIN_STATE_DIR"
    cat > "$PATCH_GREMLIN_STATE_DIR/state" <<EOF
last_run_epoch=$(( $(date +%s) - 300000 ))
last_status=no-updates
notification_sent=true
EOF
    nagios
    [ "$status" -eq 1 ]
    [[ "$output" == WARNING* ]]
}

@test "nagios: UNKNOWN when the health script is missing" {
    rm -f "$SANDBOX/bin/health"
    nagios
    [ "$status" -eq 3 ]
    [[ "$output" == UNKNOWN* ]]
}

# --------------------------------------------------------------------------
# monitoring/prometheus-exporter.sh
# --------------------------------------------------------------------------

@test "prometheus: emits well-formed metrics" {
    fake_health 0
    fresh_state
    run env PATH="$FAKEBIN:$HELPERS:$PATH" \
        PATCH_GREMLIN_HEALTH_SCRIPT="$SANDBOX/bin/health" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        bash "$REPO_ROOT/monitoring/prometheus-exporter.sh"
    [ "$status" -eq 0 ]
    # Every non-comment line must be exactly "metric_name <number>"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^[a-z_]+(\{[^}]*\})?\ -?[0-9]+(\.[0-9]+)?$ ]] || {
            echo "malformed metric line: [$line]" >&2
            return 1
        }
    done <<< "$output"
    [[ "$output" == *"patch_gremlin_health 1"* ]]
}

@test "prometheus: no duplicate metric values on a missing counter" {
    # Regression: `grep -c ... || echo 0` printed "0" twice, producing an
    # unparseable metric line.
    rm -rf "$PATCH_GREMLIN_STATE_DIR"
    fake_health 1
    run env PATH="$FAKEBIN:$HELPERS:$PATH" \
        PATCH_GREMLIN_HEALTH_SCRIPT="$SANDBOX/bin/health" \
        PATCH_GREMLIN_STATE_DIR="$PATCH_GREMLIN_STATE_DIR" \
        bash "$REPO_ROOT/monitoring/prometheus-exporter.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"0
0"* ]]
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^[a-z_]+(\{[^}]*\})?\ -?[0-9]+(\.[0-9]+)?$ ]] || return 1
    done <<< "$output"
}
