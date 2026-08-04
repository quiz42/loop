#!/usr/bin/env bash
# Open a packaged Proof Explorer through the same Python 3.9+ standard-library
# surface used by the other Proof commands.  Keeping this thin shell adapter
# makes the platform-facing entry point explicit in the repository layout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/proof-open.py" "$@"
