#!/usr/bin/env bash
# Run RLCR stop-gate checks from a command line context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" exec python3 -c 'import sys; from rlcr_loop import stop_gate_main; raise SystemExit(stop_gate_main(sys.argv[1:]))' "$@"
