#!/usr/bin/env bash
# Start an RLCR loop session.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/rlcr_loop.py" "$@"
