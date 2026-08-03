#!/usr/bin/env bash
# End-to-end export coverage for the local-v0 Proof tracer bullet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Expected: $2"
    echo "  Got: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_exit() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "exit $expected" "exit $actual"
    fi
}

proof_id() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["proof_id"])' "$1"
}

run_snapshot() {
    python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    print(f"{path.relative_to(root).as_posix()} {hashlib.sha256(path.read_bytes()).hexdigest()}")
PY
}

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "Proof export tests require Python 3.9 or newer." >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_PROJECT="$TEST_DIR/project"
RUNS_DIR="$TEST_PROJECT/.loop/rlcr"
RUN_DIR="$RUNS_DIR/2026-07-29_20-22-19"
mkdir -p "$RUNS_DIR"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$RUN_DIR"

git -C "$TEST_PROJECT" init -q
git -C "$TEST_PROJECT" config user.email proof-test@example.invalid
git -C "$TEST_PROJECT" config user.name 'Proof Test'
printf 'fixture project\n' > "$TEST_PROJECT/README.md"
git -C "$TEST_PROJECT" add README.md
git -C "$TEST_PROJECT" -c commit.gpgsign=false commit -q -m 'fixture project'

source "$PROJECT_ROOT/scripts/loop.sh"
cd "$TEST_PROJECT" || exit 1

echo "=== Test: Proof export tracer bullet ==="

FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/python3"
chmod +x "$FAKE_BIN/python3"
python_guard_output=$(PATH="$FAKE_BIN:$PATH" bash -c 'source "$1"; loop proof export --latest' _ "$PROJECT_ROOT/scripts/loop.sh" 2>&1)
python_guard_status=$?
assert_exit "Proof CLI refuses Python older than 3.9" 1 "$python_guard_status"
if [[ "$python_guard_output" == *"Python 3.9 or newer"* ]]; then
    pass "Python prerequisite failure is actionable"
else
    fail "Python prerequisite message" "Python 3.9 or newer" "$python_guard_output"
fi

before_snapshot=$(run_snapshot "$RUN_DIR")
before_status=$(git status --porcelain)
output=$(loop proof export --run "$RUN_DIR" --out "$TEST_DIR/bundle-a" 2>&1)
export_status=$?
assert_exit "clean complete Run exports" 0 "$export_status"

if [[ -f "$TEST_DIR/bundle-a/proof.json" && -f "$TEST_DIR/bundle-a/evidence/plan.md" && -f "$TEST_DIR/bundle-a/proof-data.js" ]]; then
    pass "bundle contains manifest, display data, and raw evidence"
else
    fail "bundle contents" "proof.json, proof-data.js, and evidence/plan.md" "$output"
fi

if python3 - "$TEST_DIR/bundle-a/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
assert bundle["profile"]["name"] == "local-v0"
assert bundle["run"]["terminal_state"] == "complete"
assert bundle["run"]["rounds"] == [{"index": 0}]
assert bundle["proof_id"].startswith("sha256:")
PY
then
    pass "manifest records local profile and completed Run facts"
else
    fail "manifest Run facts" "local-v0 with only completed round 0" "unexpected manifest"
fi

after_snapshot=$(run_snapshot "$RUN_DIR")
after_status=$(git status --porcelain)
if [[ "$before_snapshot" == "$after_snapshot" && "$before_status" == "$after_status" ]]; then
    pass "export leaves the Run and Git status unchanged"
else
    fail "read-only export" "unchanged Run hash and Git status" "source Run or Git status changed"
fi

loop proof export --run "$RUN_DIR" --out "$TEST_DIR/bundle-b" >/dev/null 2>&1
second_status=$?
assert_exit "same Run re-exports" 0 "$second_status"
first_id=$(proof_id "$TEST_DIR/bundle-a/proof.json")
second_id=$(proof_id "$TEST_DIR/bundle-b/proof.json")
if [[ "$first_id" == "$second_id" ]]; then
    pass "proof_id is independent of output directory and export time"
else
    fail "deterministic proof_id" "$first_id" "$second_id"
fi

loop proof export --latest --out "$TEST_DIR/bundle-latest" >/dev/null 2>&1
latest_status=$?
assert_exit "--latest finds the terminal Run" 0 "$latest_status"
if [[ "$(proof_id "$TEST_DIR/bundle-latest/proof.json")" == "$first_id" ]]; then
    pass "--latest selects the clean complete Run"
else
    fail "--latest selection" "$first_id" "$(proof_id "$TEST_DIR/bundle-latest/proof.json")"
fi

loop proof export --run "$RUN_DIR" >/dev/null 2>&1
default_status=$?
assert_exit "default identity-addressed output exports" 0 "$default_status"
digest=${first_id#sha256:}
default_dir="$TEST_PROJECT/.loop/proofs/${digest:0:12}"
if [[ -f "$default_dir/proof.json" ]]; then
    pass "default output uses the first 12 proof-id hex characters"
else
    fail "default output path" "$default_dir/proof.json" "not found"
fi

ACTIVE_DIR="$RUNS_DIR/2026-07-30_00-00-00"
mkdir -p "$ACTIVE_DIR"
cp "$RUN_DIR/plan.md" "$ACTIVE_DIR/plan.md"
cp "$RUN_DIR/goal-tracker.md" "$ACTIVE_DIR/goal-tracker.md"
cp "$RUN_DIR/complete-state.md" "$ACTIVE_DIR/state.md"
active_output=$(loop proof export --run "$ACTIVE_DIR" --out "$TEST_DIR/active-bundle" 2>&1)
active_status=$?
assert_exit "active Run is refused" 2 "$active_status"
if [[ "$active_output" == *"has not finished"* ]]; then
    pass "active Run failure explains that it has not finished"
else
    fail "active Run error" "message containing has not finished" "$active_output"
fi

mv "$ACTIVE_DIR/state.md" "$ACTIVE_DIR/finalize-state.md"
finalize_output=$(loop proof export --run "$ACTIVE_DIR" --out "$TEST_DIR/finalize-bundle" 2>&1)
finalize_status=$?
assert_exit "Finalize-phase Run is refused" 2 "$finalize_status"
if [[ "$finalize_output" == *"has not finished"* ]]; then
    pass "Finalize-phase failure explains that it has not finished"
else
    fail "Finalize-phase error" "message containing has not finished" "$finalize_output"
fi

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
exit "$TESTS_FAILED"
