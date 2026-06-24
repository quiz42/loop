#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PYTHONPATH="$(cd "$SCRIPT_DIR/.." && pwd):${PYTHONPATH:-}" exec python3 "$SCRIPT_DIR/validators.py" post-bash
