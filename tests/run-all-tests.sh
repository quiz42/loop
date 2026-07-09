#!/usr/bin/env bash
# Run the full loop test suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "Running loop test suite..."
python3 -m unittest discover -s tests -p "test_*.py" -v

echo "Running loop shell regression: test-template-loader.sh"
bash tests/test-template-loader.sh

echo "Running loop shell regression: test-loop-escape.sh"
bash tests/test-loop-escape.sh
