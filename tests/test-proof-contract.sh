#!/usr/bin/env bash
# Contract-vector tests for the Proof of Loop foundation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "Proof contract tests require Python 3.9 or newer." >&2
    exit 1
fi

python3 "$PROJECT_ROOT/tests/proof_contract/test_contract.py"
