#!/bin/bash
#
# Deprecated: kept so existing docs and muscle memory keep working.
# configure-verbosity.sh --quiet does the same thing, with backups, file
# existence checks and proper error handling.

set -euo pipefail

echo "Note: fix-verbose-now.sh is deprecated; use 'configure-verbosity.sh --quiet'." >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure-verbosity.sh" --quiet
