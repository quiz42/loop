#!/usr/bin/env bash
# Cancel the active RLCR loop.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" exec python3 -c 'import sys; from rlcr_loop import cancel_main; raise SystemExit(cancel_main(sys.argv[1:]))' "$@"
