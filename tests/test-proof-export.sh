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

NONCONTIGUOUS_DIR="$TEST_DIR/noncontiguous-ac-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/noncontiguous-ac-complete" "$NONCONTIGUOUS_DIR"
loop proof export --run "$NONCONTIGUOUS_DIR" --out "$TEST_DIR/noncontiguous-bundle" >/dev/null 2>&1
noncontiguous_status=$?
assert_exit "non-contiguous AC Run exports" 0 "$noncontiguous_status"
if python3 - "$TEST_DIR/noncontiguous-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
criteria = bundle["specification"]["acceptance_criteria"]
criteria_by_id = {criterion["id"]: criterion["text"] for criterion in criteria}
assert list(criteria_by_id) == ["ac-1", "ac-2", "ac-4", "ac-5"]
assert "ac-3" not in criteria_by_id
assert "fourth criterion" in criteria_by_id["ac-4"]
assert "fifth criterion" in criteria_by_id["ac-5"]
assert bundle["verdict"]["required_set"] == ["ac-1", "ac-2", "ac-4"]
statuses = {row["ac_id"]: row["status"] for row in bundle["verdict"]["per_ac"]}
assert statuses == {"ac-1": "met", "ac-2": "met", "ac-4": "met", "ac-5": "deferred"}
assert [row["ac_id"] for row in bundle["verdict"]["deferred"]] == ["ac-5"]
assert bundle["verdict"]["decision"] == "accept"
PY
then
    pass "explicit non-contiguous AC labels retain completed and deferred IDs"
else
    fail "non-contiguous AC mapping" "AC4 met and AC5 deferred by their explicit IDs with accept" "unexpected non-contiguous bundle"
fi

HYBRID_AC_DIR="$TEST_DIR/hyphenated-and-unlabelled-ac-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$HYBRID_AC_DIR"
python3 - "$HYBRID_AC_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert "3. AC3:" in text
assert "4. AC4:" in text
text = text.replace(
    "3. AC3: The implementation and test files are committed to git before review begins.",
    "3. AC power must remain a valid unlabelled criterion.",
    1,
)
text = text.replace("4. AC4:", "4. AC-4:", 1)
path.write_text(text, encoding="utf-8")
PY
loop proof export --run "$HYBRID_AC_DIR" --out "$TEST_DIR/hyphenated-and-unlabelled-ac-bundle" >/dev/null 2>&1
hybrid_ac_status=$?
assert_exit "hyphenated and unlabelled AC Run exports" 0 "$hybrid_ac_status"
if python3 - "$TEST_DIR/hyphenated-and-unlabelled-ac-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
criteria = bundle["specification"]["acceptance_criteria"]
criteria_by_id = {criterion["id"]: criterion["text"] for criterion in criteria}
assert list(criteria_by_id) == ["ac-1", "ac-2", "ac-3", "ac-4", "ac-5"]
assert "AC power must remain" in criteria_by_id["ac-3"]
assert "Only the Python standard library" in criteria_by_id["ac-4"]
statuses = {row["ac_id"]: row["status"] for row in bundle["verdict"]["per_ac"]}
assert statuses == {
    "ac-1": "met",
    "ac-2": "met",
    "ac-3": "met",
    "ac-4": "met",
    "ac-5": "met",
}
assert bundle["verdict"]["decision"] == "accept"
PY
then
    pass "hyphenated labels and unlabelled criteria retain their stable IDs"
else
    fail "hyphenated and unlabelled AC mapping" "AC-4 and an unlabelled third entry mapped to ac-4/ac-3" "unexpected hybrid AC bundle"
fi

MALFORMED_AC_DIR="$TEST_DIR/malformed-ac-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$MALFORMED_AC_DIR"
python3 - "$MALFORMED_AC_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("3. AC3:", "3. AC_3:", 1), encoding="utf-8")
PY
loop proof export --run "$MALFORMED_AC_DIR" --out "$TEST_DIR/malformed-ac-bundle" >/dev/null 2>&1
malformed_ac_status=$?
assert_exit "malformed AC label Run exports" 0 "$malformed_ac_status"

MALFORMED_TABLE_AC_DIR="$TEST_DIR/malformed-table-ac-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$MALFORMED_TABLE_AC_DIR"
python3 - "$MALFORMED_TABLE_AC_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(
    text.replace("| AC1, AC4, AC5 |", "| AC1.0, AC4, AC5 |", 1),
    encoding="utf-8",
)
PY
loop proof export --run "$MALFORMED_TABLE_AC_DIR" --out "$TEST_DIR/malformed-table-ac-bundle" >/dev/null 2>&1
malformed_table_ac_status=$?
assert_exit "malformed AC table reference Run exports" 0 "$malformed_table_ac_status"

PUNCTUATED_TABLE_AC_DIR="$TEST_DIR/punctuated-table-ac-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$PUNCTUATED_TABLE_AC_DIR"
python3 - "$PUNCTUATED_TABLE_AC_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
anchor = "### Explicitly Deferred"
assert anchor in text
path.write_text(
    text.replace(
        anchor,
        "| AC1? | Malformed synthetic reference | 0 | 0 | None |\n\n" + anchor,
        1,
    ),
    encoding="utf-8",
)
PY
loop proof export --run "$PUNCTUATED_TABLE_AC_DIR" --out "$TEST_DIR/punctuated-table-ac-bundle" >/dev/null 2>&1
punctuated_table_ac_status=$?
assert_exit "punctuation-suffixed AC table reference Run exports" 0 "$punctuated_table_ac_status"

DUPLICATE_AC_DIR="$TEST_DIR/duplicate-ac-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$DUPLICATE_AC_DIR"
python3 - "$DUPLICATE_AC_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("3. AC3:", "3. AC1:", 1), encoding="utf-8")
PY
loop proof export --run "$DUPLICATE_AC_DIR" --out "$TEST_DIR/duplicate-ac-bundle" >/dev/null 2>&1
duplicate_ac_status=$?
assert_exit "duplicate AC label Run exports" 0 "$duplicate_ac_status"
if python3 - "$TEST_DIR/malformed-ac-bundle/proof.json" "$TEST_DIR/malformed-table-ac-bundle/proof.json" "$TEST_DIR/punctuated-table-ac-bundle/proof.json" "$TEST_DIR/duplicate-ac-bundle/proof.json" <<'PY'
import json
import sys

malformed_label, malformed_table, punctuated, duplicate = [
    json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]
]
for bundle in (malformed_label, malformed_table, punctuated, duplicate):
    assert bundle["verdict"]["decision"] == "unverifiable"
    assert any(
        warning["reason"] == "unparseable-artifact"
        for warning in bundle["integrity"]["compile_warnings"]
    )

assert "ac-3" not in {
    criterion["id"] for criterion in malformed_label["specification"]["acceptance_criteria"]
}
malformed_table_per_ac = {
    row["ac_id"]: row["status"] for row in malformed_table["verdict"]["per_ac"]
}
assert malformed_table_per_ac["ac-1"] == "unverifiable"
punctuated_per_ac = {
    row["ac_id"]: row["status"] for row in punctuated["verdict"]["per_ac"]
}
assert punctuated_per_ac == {
    "ac-1": "met",
    "ac-2": "met",
    "ac-3": "met",
    "ac-4": "met",
    "ac-5": "met",
}
assert any(
    "AC1?" in warning["detail"]
    for warning in punctuated["integrity"]["compile_warnings"]
)
duplicate_ids = [
    criterion["id"] for criterion in duplicate["specification"]["acceptance_criteria"]
]
assert "ac-1" not in duplicate_ids
assert len(duplicate_ids) == len(set(duplicate_ids))
PY
then
    pass "malformed AC references and duplicate labels remain unparseable rather than accepted"
else
    fail "malformed AC references and duplicate labels" "unparseable-artifact with an unverifiable verdict" "unexpected malformed or duplicate AC bundle"
fi

FINDING_DIR="$TEST_DIR/open-finding-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$FINDING_DIR"
printf '\n> [P1] AC1 has an unresolved synthetic regression.\n' >> "$FINDING_DIR/round-0-review-result.md"
loop proof export --run "$FINDING_DIR" --out "$TEST_DIR/open-finding-bundle" >/dev/null 2>&1
finding_status=$?
assert_exit "complete Run with an open finding exports" 0 "$finding_status"
if python3 - "$TEST_DIR/open-finding-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
assert bundle["verdict"]["decision"] == "changes_required"
assert bundle["findings"] == [
    {
        "id": bundle["findings"][0]["id"],
        "severity": "P1",
        "status": "open",
        "found_round": 0,
        "evidence_refs": bundle["findings"][0]["evidence_refs"],
        "ac_refs": ["ac-1"],
    }
]
per_ac = {row["ac_id"]: row for row in bundle["verdict"]["per_ac"]}
assert per_ac["ac-1"]["status"] == "partial"
PY
then
    pass "open review findings are retained and block an accept verdict"
else
    fail "open finding verdict gate" "P1 finding with partial AC1 and changes_required" "unexpected finding lifecycle bundle"
fi

RESOLVED_FINDING_DIR="$TEST_DIR/resolved-finding-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$RESOLVED_FINDING_DIR"
printf '\n- [P1] AC1 had a synthetic regression.\n' >> "$RESOLVED_FINDING_DIR/round-0-review-result.md"
printf 'No P0-P9 findings remain.\n' > "$RESOLVED_FINDING_DIR/round-1-review-result.md"
loop proof export --run "$RESOLVED_FINDING_DIR" --out "$TEST_DIR/resolved-finding-bundle" >/dev/null 2>&1
resolved_finding_status=$?
assert_exit "complete Run with a resolved finding exports" 0 "$resolved_finding_status"
if python3 - "$TEST_DIR/resolved-finding-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
assert bundle["verdict"]["decision"] == "accept"
assert len(bundle["findings"]) == 1
assert bundle["findings"][0]["status"] == "resolved"
per_ac = {row["ac_id"]: row["status"] for row in bundle["verdict"]["per_ac"]}
assert per_ac == {
    "ac-1": "met",
    "ac-2": "met",
    "ac-3": "met",
    "ac-4": "met",
    "ac-5": "met",
}
PY
then
    pass "clean re-review resolves prior findings without withholding accept"
else
    fail "resolved finding lifecycle" "resolved P1 with an accept verdict" "unexpected resolved finding bundle"
fi

MIXED_FINDING_DIR="$TEST_DIR/mixed-finding-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$MIXED_FINDING_DIR"
printf '\n- [P1] AC1 had a synthetic regression.\n' >> "$MIXED_FINDING_DIR/round-0-review-result.md"
printf '%s\n' '- [P2] AC2 has a different synthetic regression.' > "$MIXED_FINDING_DIR/round-1-review-result.md"
loop proof export --run "$MIXED_FINDING_DIR" --out "$TEST_DIR/mixed-finding-bundle" >/dev/null 2>&1
mixed_finding_status=$?
assert_exit "complete Run with replaced review findings exports" 0 "$mixed_finding_status"
if python3 - "$TEST_DIR/mixed-finding-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
findings = {finding["severity"]: finding for finding in bundle["findings"]}
assert findings["P1"]["status"] == "resolved"
assert findings["P2"]["status"] == "open"
per_ac = {row["ac_id"]: row["status"] for row in bundle["verdict"]["per_ac"]}
assert per_ac["ac-1"] == "met"
assert per_ac["ac-2"] == "partial"
assert bundle["verdict"]["decision"] == "changes_required"
PY
then
    pass "a later parseable review resolves absent findings while retaining new ones"
else
    fail "mixed finding lifecycle" "resolved P1, open P2, and changes_required" "unexpected mixed finding bundle"
fi

TRUNCATED_REVIEW_DIR="$TEST_DIR/truncated-review-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$TRUNCATED_REVIEW_DIR"
python3 - "$TRUNCATED_REVIEW_DIR/round-1-review-result.md" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(
    b"> [P1] AC1 has a hidden synthetic regression.\n" + b"x" * 1048577
)
PY
loop proof export --run "$TRUNCATED_REVIEW_DIR" --out "$TEST_DIR/truncated-review-bundle" >/dev/null 2>&1
truncated_review_status=$?
assert_exit "Run with truncated later review output exports" 0 "$truncated_review_status"
if python3 - "$TEST_DIR/truncated-review-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
review = next(
    item for item in bundle["evidence"] if item["path"] == "round-1-review-result.md"
)
assert review["status"] == "truncated"
assert bundle["verdict"]["decision"] == "unverifiable"
assert any(
    warning["reason"] == "unparseable-artifact"
    and warning["target"] == "round-1-review-result.md"
    for warning in bundle["integrity"]["compile_warnings"]
)
PY
then
    pass "unavailable later review output cannot hide a finding behind an accept verdict"
else
    fail "truncated review lifecycle" "truncated later review makes the verdict unverifiable" "unexpected truncated review bundle"
fi

MISSING_REVIEW_DIR="$TEST_DIR/missing-review-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$MISSING_REVIEW_DIR"
printf '\n> [P1] AC1 has a synthetic regression awaiting re-review.\n' >> "$MISSING_REVIEW_DIR/round-0-review-result.md"
printf '%s\n' '# Round 1 Contract' 'A follow-up round was started.' > "$MISSING_REVIEW_DIR/round-1-contract.md"
printf '%s\n' '# Round 1 Summary' 'The required review result is absent.' > "$MISSING_REVIEW_DIR/round-1-summary.md"
loop proof export --run "$MISSING_REVIEW_DIR" --out "$TEST_DIR/missing-review-bundle" >/dev/null 2>&1
missing_review_status=$?
assert_exit "Run with a missing later review result exports" 0 "$missing_review_status"
if python3 - "$TEST_DIR/missing-review-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
assert bundle["verdict"]["decision"] == "unverifiable"
assert bundle["findings"][0]["severity"] == "P1"
assert bundle["findings"][0]["status"] == "unverifiable"
per_ac = {row["ac_id"]: row["status"] for row in bundle["verdict"]["per_ac"]}
assert per_ac["ac-1"] == "unverifiable"
assert any(
    warning["reason"] == "unparseable-artifact"
    and warning["target"] == "round-1-review-result.md"
    for warning in bundle["integrity"]["compile_warnings"]
)
PY
then
    pass "a later round without review evidence makes prior findings unverifiable"
else
    fail "missing review lifecycle" "unverifiable P1, AC1, and delivery verdict" "unexpected missing review bundle"
fi

REDACTED_TRACKER_DIR="$TEST_DIR/redacted-tracker-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$REDACTED_TRACKER_DIR"
printf '\nLocal path: /Users/proof-test/private\n' >> "$REDACTED_TRACKER_DIR/goal-tracker.md"
loop proof export --run "$REDACTED_TRACKER_DIR" --profile public-v0 --out "$TEST_DIR/redacted-tracker-bundle" >/dev/null 2>&1
redacted_tracker_status=$?
assert_exit "public-v0 exports when completion tracker is path-redacted" 0 "$redacted_tracker_status"
if python3 - "$TEST_DIR/redacted-tracker-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
tracker = next(item for item in bundle["evidence"] if item["path"] == "goal-tracker.md")
assert tracker["status"] == "omitted"
assert bundle["verdict"]["decision"] == "unverifiable"
per_ac = {row["ac_id"]: row for row in bundle["verdict"]["per_ac"]}
assert set(per_ac) == {"ac-1", "ac-2", "ac-3", "ac-4", "ac-5"}
assert all(
    not row["supporting"] and row["status"] == "unverifiable"
    for row in per_ac.values()
)
PY
then
    pass "redacted completion evidence cannot produce met acceptance criteria"
else
    fail "profile-relative completion evidence" "omitted tracker makes all ACs unverifiable" "unexpected redacted tracker bundle"
fi

TRUNCATED_TRACKER_DIR="$TEST_DIR/truncated-tracker-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$TRUNCATED_TRACKER_DIR"
python3 - "$TRUNCATED_TRACKER_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes() + b"x" * 1048577)
PY
loop proof export --run "$TRUNCATED_TRACKER_DIR" --out "$TEST_DIR/truncated-tracker-bundle" >/dev/null 2>&1
truncated_tracker_status=$?
assert_exit "Run with truncated required evidence exports" 0 "$truncated_tracker_status"
if python3 - "$TEST_DIR/truncated-tracker-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
tracker = next(item for item in bundle["evidence"] if item["path"] == "goal-tracker.md")
assert tracker["status"] == "truncated"
assert bundle["verdict"]["decision"] == "unverifiable"
per_ac = {row["ac_id"]: row["status"] for row in bundle["verdict"]["per_ac"]}
assert per_ac == {
    "ac-1": "unverifiable",
    "ac-2": "unverifiable",
    "ac-3": "unverifiable",
    "ac-4": "unverifiable",
    "ac-5": "unverifiable",
}
PY
then
    pass "truncated required evidence cannot produce an accept verdict"
else
    fail "truncated required evidence verdict" "truncated tracker makes all ACs unverifiable" "unexpected truncated tracker bundle"
fi

UNEXPECTED_DIR="$RUNS_DIR/2026-07-30_01-00-00"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/unexpected-derived" "$UNEXPECTED_DIR"
loop proof export --run "$UNEXPECTED_DIR" --out "$TEST_DIR/unexpected-bundle" >/dev/null 2>&1
unexpected_status=$?
assert_exit "unexpected Run exports" 0 "$unexpected_status"

CANCEL_DIR="$RUNS_DIR/2026-07-30_02-00-00"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/cancel-after-review" "$CANCEL_DIR"
loop proof export --run "$CANCEL_DIR" --out "$TEST_DIR/cancel-bundle" >/dev/null 2>&1
cancel_status=$?
assert_exit "cancel Run exports" 0 "$cancel_status"
if python3 - "$TEST_DIR/unexpected-bundle/proof.json" "$TEST_DIR/cancel-bundle/proof.json" <<'PY'
import json
import sys

unexpected = json.load(open(sys.argv[1], encoding="utf-8"))
cancel = json.load(open(sys.argv[2], encoding="utf-8"))
assert unexpected["run"]["terminal_state"] == "unexpected"
unexpected_per_ac = {
    row["ac_id"]: row["status"] for row in unexpected["verdict"]["per_ac"]
}
assert unexpected_per_ac == {
    "ac-1": "met",
    "ac-2": "met",
    "ac-3": "met",
    "ac-4": "met",
    "ac-5": "met",
}
assert unexpected["verdict"]["decision"] == "changes_required"
assert unexpected["verdict"]["decision"] != "accept"
assert cancel["run"]["terminal_state"] == "cancel"
assert cancel["verdict"]["decision"] == "changes_required"
assert cancel["verdict"]["decision"] != "accept"
marker = next(item for item in cancel["evidence"] if item["path"] == ".cancel-requested")
assert marker["kind"] == "unknown"
assert marker["status"] == "included"
assert not any(warning.get("target") == ".cancel-requested" for warning in cancel["integrity"]["compile_warnings"])
PY
then
    pass "non-complete Runs never export an accept verdict and cancellation marker stays warning-free"
else
    fail "non-complete verdict and cancellation marker" "changes_required with retained warning-free marker" "unexpected Run or cancel Bundle mismatch"
fi

PUBLIC_ENTROPY_DIR="$TEST_DIR/public-entropy-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$PUBLIC_ENTROPY_DIR"
entropy_candidate='l4Z_Xe-8Ar9yQw2Nv5KuD7cmW0bJx3fT'
printf 'https://example.invalid/%s\n' "$entropy_candidate" > "$PUBLIC_ENTROPY_DIR/entropy-fixture.txt"
public_entropy_output=$(loop proof export --run "$PUBLIC_ENTROPY_DIR" --profile public-v0 --out "$TEST_DIR/public-entropy-bundle" 2>&1)
public_entropy_status=$?
assert_exit "public-v0 rejects high-entropy evidence" 3 "$public_entropy_status"
if [[ "$public_entropy_output" == *"entropy-fixture.txt"* && "$public_entropy_output" == *"high-entropy"* && "$public_entropy_output" != *"$entropy_candidate"* ]]; then
    pass "high-entropy failure names its file and match type without exposing the value"
else
    fail "high-entropy diagnostic redaction" "file and match type named without secret value" "diagnostic redaction contract failed"
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
