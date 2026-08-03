#!/usr/bin/env bash
# End-to-end verifier coverage for the local-v0 Proof tracer bullet.

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

assert_report() {
    local name="$1"
    local report="$2"
    local expected_status="$3"
    local expected_reason="${4:-}"
    if python3 - "$report" "$expected_status" "$expected_reason" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["status"] == sys.argv[2]
if sys.argv[3]:
    assert any(item.get("reason") == sys.argv[3] for item in report["reasons"])
PY
    then
        pass "$name"
    else
        fail "$name" "status $expected_status${expected_reason:+ with $expected_reason}" "$report"
    fi
}

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "Proof verifier tests require Python 3.9 or newer." >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_PROJECT="$TEST_DIR/project"
RUN_DIR="$TEST_PROJECT/.loop/rlcr/2026-07-29_20-22-19"
mkdir -p "$(dirname "$RUN_DIR")"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$RUN_DIR"

git -C "$TEST_PROJECT" init -q
git -C "$TEST_PROJECT" config user.email proof-test@example.invalid
git -C "$TEST_PROJECT" config user.name 'Proof Test'
printf 'fixture project\n' > "$TEST_PROJECT/README.md"
git -C "$TEST_PROJECT" add README.md
git -C "$TEST_PROJECT" -c commit.gpgsign=false commit -q -m 'fixture project'

source "$PROJECT_ROOT/scripts/loop.sh"
cd "$TEST_PROJECT" || exit 1
loop proof export --run "$RUN_DIR" --out "$TEST_DIR/clean" >/dev/null 2>&1
setup_status=$?
if [[ "$setup_status" -ne 0 ]]; then
    echo "Unable to create the clean verification fixture." >&2
    exit 1
fi

echo "=== Test: Proof verify tracer bullet ==="

clean_report=$(loop proof verify "$TEST_DIR/clean" --json)
clean_status=$?
assert_exit "clean Bundle verifies" 0 "$clean_status"
assert_report "clean Bundle reports valid JSON" "$clean_report" valid
if python3 - "$clean_report" <<'PY'
import json
import sys

assert json.loads(sys.argv[1])["warnings"] == []
PY
then
    pass "clean Bundle has no unexpected validation warnings"
else
    fail "clean Bundle warnings" "an empty warning list" "$clean_report"
fi

cp -R "$TEST_DIR/clean" "$TEST_DIR/tampered-evidence"
printf 'tampered evidence byte\n' >> "$TEST_DIR/tampered-evidence/evidence/plan.md"
evidence_report=$(loop proof verify "$TEST_DIR/tampered-evidence" --json)
evidence_status=$?
assert_exit "changed Evidence bytes are invalid" 3 "$evidence_status"
assert_report "changed Evidence names hash mismatch" "$evidence_report" invalid hash-mismatch
if [[ "$evidence_report" == *'"target": "plan.md"'* ]]; then
    pass "hash mismatch names the changed evidence path"
else
    fail "hash mismatch target" "plan.md" "$evidence_report"
fi

cp -R "$TEST_DIR/clean" "$TEST_DIR/tampered-manifest"
python3 - "$TEST_DIR/tampered-manifest/proof.json" <<'PY'
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["verdict"]["decision"] = "changes_required"
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
manifest_report=$(loop proof verify "$TEST_DIR/tampered-manifest" --json)
manifest_status=$?
assert_exit "changed proof.json field is invalid" 3 "$manifest_status"
assert_report "changed proof.json names proof-id mismatch" "$manifest_report" invalid proof-id-mismatch
if [[ "$manifest_report" == *'"target": "proof.json"'* ]]; then
    pass "proof-id mismatch names proof.json"
else
    fail "proof-id mismatch target" "proof.json" "$manifest_report"
fi

cp -R "$TEST_DIR/clean" "$TEST_DIR/missing-evidence"
rm "$TEST_DIR/missing-evidence/evidence/plan.md"
missing_report=$(loop proof verify "$TEST_DIR/missing-evidence" --json)
missing_status=$?
assert_exit "missing included Evidence is invalid" 3 "$missing_status"
assert_report "missing Evidence names missing-file" "$missing_report" invalid missing-file

cp -R "$TEST_DIR/clean" "$TEST_DIR/display-only-tamper"
printf '\n// noncanonical display-only change\n' >> "$TEST_DIR/display-only-tamper/proof-data.js"
display_report=$(loop proof verify "$TEST_DIR/display-only-tamper" --json)
display_status=$?
assert_exit "proof-data.js is outside the canonical verify surface" 0 "$display_status"
assert_report "display-only tamper remains valid" "$display_report" valid

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
exit "$TESTS_FAILED"
