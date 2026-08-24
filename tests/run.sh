#!/bin/bash
#
# Canonical entry point for the Patch Gremlin test suite.
#
# Distro bats versions vary widely: --print-output-on-failure only exists in
# bats >= 1.5, and Ubuntu 22.04 ships 1.2.1. Detect support rather than
# hardcoding the flag, so the same command works everywhere.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
    echo "error: bats is not installed." >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y bats" >&2
    echo "  Fedora:        sudo dnf install -y bats" >&2
    echo "  From source:   git clone --depth 1 https://github.com/bats-core/bats-core \\" >&2
    echo "                   && sudo ./bats-core/install.sh /usr/local" >&2
    exit 2
fi

declare -a flags=()
if bats --help 2>&1 | grep -q -- '--print-output-on-failure'; then
    flags+=(--print-output-on-failure)
fi

echo "Using $(bats --version)"

# Expand the array only when non-empty: "${flags[@]}" on an empty array errors
# under `set -u` on bash < 4.4.
if [[ ${#flags[@]} -gt 0 ]]; then
    exec bats "${flags[@]}" "$@" "$TESTS_DIR"
fi
exec bats "$@" "$TESTS_DIR"
