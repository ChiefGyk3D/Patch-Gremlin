# Shared bats helpers for the Patch Gremlin suite.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
FIXTURES="$REPO_ROOT/tests/fixtures"
export FIXTURES
HELPERS="$REPO_ROOT/tests/helpers"
export HELPERS

# Put the command stubs ahead of the real binaries so scripts under test never
# touch the host system.
stub_path() {
    PATH="$HELPERS:$PATH"
    export PATH
}

setup_sandbox() {
    # Pin the package family for every test. The installer and notifier both
    # otherwise read /etc/os-release, so any assertion about apt or dnf paths
    # would silently depend on whichever distro the suite happens to run on -
    # which is exactly how the Fedora and Rocky CI jobs failed while Debian
    # and Ubuntu passed. Tests that want the RHEL branch override this.
    #
    # Guard: `PATCH_GREMLIN_OS_TYPE=rhel ./tests/run.sh` must still pass 100%.
    # If it does not, some staged install is inheriting the host family.
    export PATCH_GREMLIN_OS_TYPE="${PATCH_GREMLIN_OS_TYPE:-debian}"

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    STUB_CAPTURE_DIR="$SANDBOX/calls"
    export STUB_CAPTURE_DIR
    mkdir -p "$STUB_CAPTURE_DIR"
    export PATCH_GREMLIN_STATE_DIR="$SANDBOX/state"
    export PATCH_GREMLIN_SECRETS_FILE="$SANDBOX/secrets.conf"
    export PATCH_GREMLIN_CONFIG_FILE="$SANDBOX/config.sh"
    stub_path
}

teardown_sandbox() {
    [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
    return 0
}

# Source update-notifier.sh for unit testing without running main().
load_notifier() {
    export PATCH_GREMLIN_SOURCE_ONLY=1
    # shellcheck source=/dev/null
    source "$REPO_ROOT/update-notifier.sh"
}

write_secrets() {
    cat > "$PATCH_GREMLIN_SECRETS_FILE" <<EOF
SECRET_MODE="local"
$*
EOF
    chmod 600 "$PATCH_GREMLIN_SECRETS_FILE"
}

# Assert every captured payload is syntactically valid JSON.
assert_payloads_valid_json() {
    local found=0 f
    for f in "$STUB_CAPTURE_DIR"/payload-*; do
        [[ -e "$f" ]] || continue
        found=1
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f"; then
            echo "INVALID JSON in $f:" >&2
            cat "$f" >&2
            return 1
        fi
    done
    [[ $found -eq 1 ]] || { echo "no payloads captured" >&2; return 1; }
    return 0
}

payload_field() {
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1" "$2"
}
