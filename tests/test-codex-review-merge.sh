#!/usr/bin/env bash
#
# Tests for Code Review log file analysis behavior
#
# Tests that detect_review_issues() correctly:
# - Detects [P0-9] patterns in first 10 characters of each line
# - Scans only the last 50 lines of the log file
# - Extracts content from the first matching line to the end
# - Returns appropriate exit codes
#
# Algorithm being tested:
# 1. Scan the last 50 lines of the log file
# 2. Find the first line where [P?] (? is a digit) appears in the first 10 characters
# 3. If found: extract from that line to the end and output it
# 4. If not found: no issues, return 1
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; echo "  Expected: $2"; echo "  Got: $3"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Setup test environment. Cleanup restores write permission first: two tests
# below deliberately leave a read-only directory or a mode-000 record behind
# when they fail mid-way, and rm -rf alone cannot clear those.
TEST_DIR=$(mktemp -d)
trap 'chmod -R u+w "$TEST_DIR" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT

# Set up isolated cache directory
export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

# Source the loop-common.sh which contains detect_review_issues
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

echo "=== Test: Code Review Log File Analysis ==="
echo ""

# Setup test loop directory structure
setup_test_env() {
    LOOP_DIR="$TEST_DIR/.loop/rlcr/2024-01-01_12-00-00"
    CACHE_DIR="$XDG_CACHE_HOME/loop/codex-review"
    mkdir -p "$LOOP_DIR"
    mkdir -p "$CACHE_DIR"
    export LOOP_DIR CACHE_DIR
}

# ========================================
# Test 1: [P?] in first 10 chars - should detect
# ========================================
echo "Test 1: detect_review_issues finds [P?] in first 10 characters"
setup_test_env

cat > "$CACHE_DIR/round-1-codex-review.log" << 'EOF'
Some debug output from codex
More debug lines
thinking about the code
- [P1] Missing null check - /path/to/file.py:42-45
  The function does not check for null input before processing.
- [P2] Another issue - /path/to/other.py:10-15
  Description of the issue.
EOF

set +e
OUTPUT=$(detect_review_issues 1 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* && "$OUTPUT" == *'[P2]'* ]]; then
    pass "Issues detected with [P?] in first 10 chars"
else
    fail "Issues in first 10 chars" "return 0, output contains [P1] and [P2]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 2: [P?] NOT in first 10 chars - should NOT detect
# ========================================
echo "Test 2: detect_review_issues ignores [P?] not in first 10 characters"
setup_test_env

cat > "$CACHE_DIR/round-2-codex-review.log" << 'EOF'
Some debug output from codex
More debug lines
This line has [P1] but not in first 10 chars - should be ignored
Another line mentioning [P2] somewhere in the middle
Final line of output
EOF

set +e
OUTPUT=$(detect_review_issues 2 2>/dev/null)
RESULT=$?
set -e

# [P?] is not in first 10 chars, so should return 1 (no issues found)
if [[ $RESULT -eq 1 ]]; then
    pass "[P?] not in first 10 chars returns 1 (no issues)"
else
    fail "[P?] position check" "return 1 (no issues)" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 3: No [P?] at all - should return 1
# ========================================
echo "Test 3: detect_review_issues returns 1 when no [P?] patterns"
setup_test_env

cat > "$CACHE_DIR/round-3-codex-review.log" << 'EOF'
Code review complete
No issues found
All checks passed
The code looks good
EOF

set +e
OUTPUT=$(detect_review_issues 3 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 1 ]]; then
    pass "No [P?] returns 1"
else
    fail "No issues detection" "return 1" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 3b: A clean review is recorded in the Run, not only in the cache log
# ========================================
# Issue #33: the clean re-review is the one artifact that closes a finding, and
# it used to be produced and discarded. The Proof layer resolves a finding only
# against a later parseable review result that no longer names it.
echo "Test 3b: detect_review_issues records the clean result in the Run"

CLEAN_RESULT_FILE="$LOOP_DIR/round-3-review-result.md"
if [[ -f "$CLEAN_RESULT_FILE" ]]; then
    pass "Clean review writes round-N-review-result.md"
else
    fail "Clean review record" "$CLEAN_RESULT_FILE exists" "no file written"
fi

# The record must read as a *clean* review, not an unparseable one. The review
# readers scan the first ten characters of each line for a bracketed severity
# token, and a token that is not a single digit -- `[P0-9]` written literally --
# reads as malformed, which would leave the findings it was meant to resolve
# `unverifiable` instead. This is the assertion that keeps the wording honest.
if ! command -v python3 >/dev/null 2>&1; then
    pass "Clean review record parse skipped (python3 unavailable)"
elif [[ ! -f "$CLEAN_RESULT_FILE" ]]; then
    # Not a skip: with no record there is nothing to parse, and reporting that
    # as a pass is how this assertion would quietly stop testing anything.
    fail "Clean review record parse" "a record to parse" "no file written"
else
    CLEAN_PARSE=$(cd "$PROJECT_ROOT" && python3 - "$CLEAN_RESULT_FILE" <<'PY'
import sys
sys.path.insert(0, ".")
from proof.core import parse_review_result

facts = parse_review_result(open(sys.argv[1], encoding="utf-8").read())
print(
    "present=%s malformed=%d markers=%d"
    % (facts.present, len(facts.malformed_markers), len(facts.markers))
)
PY
)
    if [[ "$CLEAN_PARSE" == "present=True malformed=0 markers=0" ]]; then
        pass "Clean review record parses as present, well-formed and finding-free"
    else
        fail "Clean review record parse" "present=True malformed=0 markers=0" "$CLEAN_PARSE"
    fi
fi

# An absolute path here would be withheld or masked by a public profile, which
# is the failure mode issue #32 recorded for the findings path.
if [[ -f "$CLEAN_RESULT_FILE" ]] && ! grep -qE '/(Users|home)/[^/[:space:]]+' "$CLEAN_RESULT_FILE"; then
    pass "Clean review record carries no absolute home path"
else
    fail "Clean review record paths" "no absolute home path" "$(cat "$CLEAN_RESULT_FILE" 2>/dev/null)"
fi

# A findings run must still overwrite the record with the findings themselves,
# so a clean pass followed by a dirty one does not leave a stale all-clear.
setup_test_env
cat > "$CACHE_DIR/round-9-codex-review.log" << 'EOF'
Code review complete
No issues found
EOF
set +e
detect_review_issues 9 >/dev/null 2>&1
cat > "$CACHE_DIR/round-9-codex-review.log" << 'EOF'
Reviewing again
- [P1] Regression reintroduced - file.py:1-2
EOF
detect_review_issues 9 >/dev/null 2>&1
set -e
if grep -q '\[P1\]' "$LOOP_DIR/round-9-review-result.md" && \
   ! grep -q 'No severity-marked finding' "$LOOP_DIR/round-9-review-result.md"; then
    pass "A later findings review replaces the clean record"
else
    fail "Clean record replacement" "the findings review only" \
        "$(cat "$LOOP_DIR/round-9-review-result.md" 2>/dev/null)"
fi

# ========================================
# Test 3c: An all-clear is only written when the WHOLE log is clean
# ========================================
# The extraction window is the last 50 lines, because findings appear at the end
# and a full-file scan invites false positives. That trade is right for pulling
# findings out. It is wrong for asserting that none exist: a canonical marker
# earlier in the log, or a marker-shaped token that is not a single digit, means
# the detector has NOT established a clean review.
#
# Recording one anyway is a false green with teeth. The Proof layer resolves
# every finding still open in the Run against that record, so one missed marker
# launders the lot and can carry a Run with unfixed work to `accept`. Verified
# end to end before this gate existed: `changes_required` became `accept`.
echo "Test 3c: detect_review_issues does not assert a clean review it cannot establish"

# Usage: assert_no_clean_record <round> <label>
assert_no_clean_record() {
    local round="$1"
    local label="$2"
    set +e
    detect_review_issues "$round" >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 1 ]] && [[ ! -f "$LOOP_DIR/round-${round}-review-result.md" ]]; then
        pass "$label writes no clean record"
    else
        fail "$label" "return 1 and no record" \
            "return $rc, record exists: $(test -f "$LOOP_DIR/round-${round}-review-result.md" && echo yes || echo no)"
    fi
}

setup_test_env

# A canonical marker outside the extraction window. tests above already assert
# the detector reports this log as clean; the point here is that it must not
# write that down.
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    echo "- [P1] Outside the window - /path/to/file.py:1"
    for i in $(seq 6 70); do echo "More output line $i - no issues here"; done
} > "$CACHE_DIR/round-20-codex-review.log"
assert_no_clean_record 20 "a canonical marker outside the window"

# Marker-shaped but not a single digit. parse_review_result would score these as
# malformed and hold the round unparseable; a synthetic all-clear hides them.
printf 'review output\n- [P10] Severity out of range - f.py:1\n' \
    > "$CACHE_DIR/round-21-codex-review.log"
assert_no_clean_record 21 "a [P10] token"

printf 'review output\n- [P0-9] Literal class, not a severity - f.py:1\n' \
    > "$CACHE_DIR/round-22-codex-review.log"
assert_no_clean_record 22 "a [P0-9] token"

# A genuinely clean log still earns its record, or the gate is useless.
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-23-codex-review.log"
set +e
detect_review_issues 23 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-23-review-result.md" ]]; then
    pass "a genuinely clean log still earns its record"
else
    fail "clean log record" "a record" "no file written"
fi

# An earlier attempt at the same round may have left an all-clear on disk. Once
# the outcome is ambiguous that record cannot stand.
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-24-codex-review.log"
set +e
detect_review_issues 24 >/dev/null 2>&1
set -e
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    echo "- [P1] Reported on the retry, outside the window - f.py:1"
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-24-codex-review.log"
assert_no_clean_record 24 "an ambiguous retry after a clean pass"

# ...but an extracted findings record is evidence, and must survive the same
# retry. Only our own all-clear is ever dropped.
printf 'review output\n- [P1] Genuine finding - f.py:1\n' \
    > "$CACHE_DIR/round-25-codex-review.log"
set +e
detect_review_issues 25 >/dev/null 2>&1
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    echo "- [P2] Different marker, outside the window - f.py:1"
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-25-codex-review.log"
detect_review_issues 25 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-25-review-result.md" ]] && \
   grep -q '\[P1\]' "$LOOP_DIR/round-25-review-result.md"; then
    pass "an ambiguous retry keeps an extracted findings record"
else
    fail "findings record retention" "the [P1] record preserved" \
        "$(cat "$LOOP_DIR/round-25-review-result.md" 2>/dev/null || echo 'deleted')"
fi

# ========================================
# Test 3d: The shell reads a marker exactly where the Proof layer does
# ========================================
# `_FINDING_MARKER` in proof/core.py anchors `^.{0,9}?` before the marker: the
# token has to *start* within the first ten columns. The shell used to truncate
# each line to ten characters and require the whole token inside them, which is
# a different and narrower rule. A marker indented by seven spaces closes in
# column 11, so the shell threw the closing bracket away and read the line as
# clean while the Proof layer read it as a finding.
#
# A gate that reads less than the Proof layer is worse than no gate: the
# difference is exactly the set of findings it certifies as absent. Measured
# before this fix -- an indented [P1] took a Run to `accept` with the finding
# `resolved`, while the review still reported it.
echo "Test 3d: an indented marker is read the same way on both sides"

setup_test_env

# Column 8. Extraction now sees it, so this is a findings run, not a clean one.
printf 'Reviewing the diff\n       [P1] Indented finding - f.py:1-2\nDone.\n' \
    > "$CACHE_DIR/round-30-codex-review.log"
set +e
detect_review_issues 30 >/dev/null 2>&1
RESULT=$?
set -e
if [[ $RESULT -eq 0 ]] && grep -q '\[P1\]' "$LOOP_DIR/round-30-review-result.md" 2>/dev/null; then
    pass "an indented canonical marker is extracted, not called clean"
else
    fail "indented marker extraction" "return 0 and a findings record" \
        "return $RESULT, file: $(cat "$LOOP_DIR/round-30-review-result.md" 2>/dev/null || echo none)"
fi

# The same marker outside the extraction window. Extraction cannot see it; the
# whole-log guard must, or the all-clear returns by the back door.
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf '       [P1] Indented and out of window - f.py:1\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-31-codex-review.log"
assert_no_clean_record 31 "an indented marker outside the window"

# Indented and malformed, at the far edge of the anchor.
printf 'output\n         [P0-9] Indented literal class - f.py:1\n' \
    > "$CACHE_DIR/round-32-codex-review.log"
assert_no_clean_record 32 "an indented [P0-9] at column 10"

printf 'output\n       [P10] Indented severity out of range - f.py:1\n' \
    > "$CACHE_DIR/round-33-codex-review.log"
assert_no_clean_record 33 "an indented [P10]"

# Column 11 is past the anchor on both sides. If this stopped being ignored the
# fix would have widened the rule rather than corrected it.
printf 'output\n          [P1] Past the anchor - f.py:1\n' \
    > "$CACHE_DIR/round-34-codex-review.log"
set +e
detect_review_issues 34 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-34-review-result.md" ]]; then
    pass "a marker past column 10 is still outside the rule, as it is for the Proof layer"
else
    fail "column 11 boundary" "a clean record" "no record written"
fi

# An active finding from an earlier round must not be cleared by a round whose
# review the detector could not read. This is the shape that reached `accept`.
# Round numbers here are unique across the file: setup_test_env reuses one
# directory, so a number an earlier test used already has a record on disk.
setup_test_env
printf -- '- [P1] Earlier genuine finding - f.py:1-2\n' \
    > "$LOOP_DIR/round-35-review-result.md"
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf '       [P1] Still reported, indented and out of window - f.py:1-2\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-36-codex-review.log"
set +e
detect_review_issues 36 >/dev/null 2>&1
set -e
if [[ ! -f "$LOOP_DIR/round-36-review-result.md" ]] && \
   grep -q '\[P1\]' "$LOOP_DIR/round-35-review-result.md"; then
    pass "an unreadable round writes nothing that could resolve an open finding"
else
    fail "active finding protection" "no round-36 record, round-35 intact" \
        "round-36 exists: $(test -f "$LOOP_DIR/round-36-review-result.md" && echo yes || echo no)"
fi

# ========================================
# Test 3e: Deleting a stale record is decided structurally
# ========================================
# The ambiguity path drops an all-clear it can no longer support. Deciding which
# record that is from a *line in the file* does not work: a findings record is
# copied verbatim from review output, so review output containing that same line
# makes a real finding look like our own record and deletes it. Reproduced: a
# genuine [P1] record was removed and the caller proceeded to finalize.
#
# A findings record always begins at the marker line that triggered extraction,
# so "carries no marker" is a property of the all-clear that review output
# cannot forge.
echo "Test 3e: an ambiguous retry never deletes an extracted findings record"

setup_test_env
printf 'scanning\n- [P1] Genuine finding - f.py:1-2\n  Detail line.\n%s\n' \
    "$CLEAN_REVIEW_MARKER" > "$CACHE_DIR/round-40-codex-review.log"
set +e
detect_review_issues 40 >/dev/null 2>&1
set -e
if grep -q "^${CLEAN_REVIEW_MARKER}$" "$LOOP_DIR/round-40-review-result.md" 2>/dev/null; then
    pass "the extracted record does contain the colliding line"
else
    fail "collision setup" "an extracted record carrying the line" \
        "$(cat "$LOOP_DIR/round-40-review-result.md" 2>/dev/null || echo none)"
fi

printf 'retrying\n- [P10] ambiguous token - f.py:1\n' \
    > "$CACHE_DIR/round-40-codex-review.log"
set +e
detect_review_issues 40 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-40-review-result.md" ]] && \
   grep -q '\[P1\]' "$LOOP_DIR/round-40-review-result.md"; then
    pass "and the genuine finding survives the ambiguous retry"
else
    fail "collision protection" "the [P1] record preserved" \
        "$(cat "$LOOP_DIR/round-40-review-result.md" 2>/dev/null || echo deleted)"
fi

# ========================================
# Test 3f: The gate never contradicts parse_review_result
# ========================================
# This is the invariant, asserted directly rather than case by case: an
# all-clear may be written only for review text that `parse_review_result`
# reads as carrying no marker at all, canonical or malformed.
#
# It is asserted this way because the case-by-case version kept passing while
# the property failed. The hook used to re-implement the grammar in awk and the
# two drifted three times -- on whether a marker must fit inside ten columns or
# merely start there, on byte versus character offsets for non-ASCII prefixes,
# and on a token spanning a line break. Each round of tests covered the shapes
# already known to differ. The grammar now lives only in proof/core.py and the
# hook reads it through scripts/review-markers.py, so this checks the two agree
# on inputs chosen to break the old implementations.
echo "Test 3f: an all-clear never contradicts parse_review_result"

PARITY_ROUND=50

# Usage: assert_gate_parity <label> <log-file>
assert_gate_parity() {
    local label="$1"
    local log="$2"
    PARITY_ROUND=$((PARITY_ROUND + 1))
    cp "$log" "$CACHE_DIR/round-${PARITY_ROUND}-codex-review.log"
    set +e
    detect_review_issues "$PARITY_ROUND" >/dev/null 2>&1
    set -e

    local record="$LOOP_DIR/round-${PARITY_ROUND}-review-result.md"
    local wrote_all_clear=no
    if [[ -f "$record" ]] && grep -q "^${CLEAN_REVIEW_MARKER}$" "$record"; then
        wrote_all_clear=yes
    fi

    local proof_sees
    proof_sees=$(cd "$PROJECT_ROOT" && python3 - "$log" <<'PY'
import sys
sys.path.insert(0, ".")
from proof.core import parse_review_result

try:
    text = open(sys.argv[1], encoding="utf-8").read()
except (OSError, UnicodeError):
    print("unreadable")
    raise SystemExit(0)
facts = parse_review_result(text)
print("none" if not facts.markers and not facts.malformed_markers else "marker")
PY
)
    # The implication that matters: an all-clear only where Proof sees nothing.
    # The hook may withhold one where Proof sees nothing too -- withholding is
    # always safe -- so the converse is not asserted.
    if [[ "$wrote_all_clear" == "yes" && "$proof_sees" != "none" ]]; then
        fail "gate parity: $label" "no all-clear when Proof reads a marker" \
            "all-clear written, Proof reads: $proof_sees"
    else
        pass "gate parity: $label (all-clear=$wrote_all_clear, proof=$proof_sees)"
    fi
}

# Seven U+00E9 then a canonical marker. Python counts characters, so the marker
# starts at character 8 and is a valid P1; awk's RSTART counts bytes and put it
# at 15, past the anchor, so the old gate called this clean.
printf '\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9[P1] UTF-8 prefixed finding - f.py:1\n' \
    > "$TEST_DIR/utf8-canonical.log"
assert_gate_parity "UTF-8 prefixed canonical marker" "$TEST_DIR/utf8-canonical.log"

# The same, pushed outside the extraction window, so only the gate can catch it.
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf '\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9[P1] UTF-8, out of window - f.py:1\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$TEST_DIR/utf8-out-of-window.log"
assert_gate_parity "UTF-8 prefixed marker outside the window" "$TEST_DIR/utf8-out-of-window.log"

printf '\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9[P10] UTF-8 prefixed, out of range - f.py:1\n' \
    > "$TEST_DIR/utf8-p10.log"
assert_gate_parity "UTF-8 prefixed [P10]" "$TEST_DIR/utf8-p10.log"

printf '\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9[P0-9] UTF-8 prefixed literal class - f.py:1\n' \
    > "$TEST_DIR/utf8-p09.log"
assert_gate_parity "UTF-8 prefixed [P0-9]" "$TEST_DIR/utf8-p09.log"

# `_FINDING_MARKER_ATTEMPT` permits a newline inside the token, because its
# `[^\]]*` class does. A line-oriented scan cannot see this one at all.
printf 'review output\n       [P\ncontinuation] trailing\n' \
    > "$TEST_DIR/multiline-token.log"
assert_gate_parity "a marker token spanning a line break" "$TEST_DIR/multiline-token.log"

# Controls, so the harness is not passing because it never writes an all-clear.
printf 'Code review complete\nNothing to report\n' > "$TEST_DIR/parity-clean.log"
assert_gate_parity "a genuinely clean log" "$TEST_DIR/parity-clean.log"
if [[ -f "$LOOP_DIR/round-${PARITY_ROUND}-review-result.md" ]]; then
    pass "and the clean control does earn its all-clear"
else
    fail "parity clean control" "an all-clear for a clean log" "no record written"
fi

# For each ambiguous class, a finding already open must stay open: the whole
# danger is that an all-clear resolves it.
setup_test_env
printf -- '- [P1] Earlier genuine finding - f.py:1-2\n' \
    > "$LOOP_DIR/round-60-review-result.md"
for probe in utf8-out-of-window utf8-p10 multiline-token; do
    cp "$TEST_DIR/$probe.log" "$CACHE_DIR/round-61-codex-review.log"
    rm -f "$LOOP_DIR/round-61-review-result.md"
    set +e
    detect_review_issues 61 >/dev/null 2>&1
    set -e
    if [[ ! -f "$LOOP_DIR/round-61-review-result.md" ]] && \
       grep -q '\[P1\]' "$LOOP_DIR/round-60-review-result.md"; then
        pass "$probe leaves an already-open finding unresolved"
    else
        fail "$probe active finding" "no record, earlier finding intact" \
            "record exists: $(test -f "$LOOP_DIR/round-61-review-result.md" && echo yes || echo no)"
    fi
done

# ========================================
# Test 3g: A scan that cannot run is not a clean scan
# ========================================
# Issue #28 is the cautionary tale: a hook that tested only for its own failure
# codes read `python3: command not found` (127) as a pass and skipped the gate
# in silence. "Could not look" must never be recorded as "looked and saw
# nothing", so the scanner reports those separately and the gate demands the
# second one.
echo "Test 3g: an unavailable scanner withholds the all-clear"

setup_test_env
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-70-codex-review.log"
SAVED_SCANNER="$REVIEW_MARKER_SCANNER"
REVIEW_MARKER_SCANNER="$TEST_DIR/no-such-scanner.py"
set +e
detect_review_issues 70 >/dev/null 2>&1
SCANNER_RC=$?
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if [[ $SCANNER_RC -eq 1 ]] && [[ ! -f "$LOOP_DIR/round-70-review-result.md" ]]; then
    pass "a clean log earns no all-clear when the scanner cannot run"
else
    fail "scanner unavailable" "return 1 and no record" \
        "return $SCANNER_RC, record: $(test -f "$LOOP_DIR/round-70-review-result.md" && echo yes || echo no)"
fi

# The same clean log does earn one once the scanner is back, so the assertion
# above is about the scanner and not about the log.
set +e
detect_review_issues 70 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-70-review-result.md" ]]; then
    pass "and earns it once the scanner is available again"
else
    fail "scanner restored" "an all-clear" "no record written"
fi

# ========================================
# Test 3h: The published record survives every line-counting disagreement
# ========================================
# The scanner used to report a line number over decoded text -- where a bare CR
# is a line break -- and the shell handed it to sed, where it is not. The
# extraction started past the marker and published a marker-free record, which
# parses as a clean re-review and resolves every open finding. The fix removes
# the translation entirely: the scanner cuts the suffix out of the text it
# scanned, and no line number crosses back into shell arithmetic.
#
# Each case pins one separator class that splits differently somewhere -- in
# universal-newline decoding, in str.splitlines, in sed -- and asserts the only
# fact that matters downstream: the published record still carries the marker
# the log carried.
echo "Test 3h: extraction survives CR, CRLF and exotic line separators"

setup_test_env

# Usage: assert_marker_survives <round> <label>
assert_marker_survives() {
    local round="$1"
    local label="$2"
    set +e
    detect_review_issues "$round" >/dev/null 2>&1
    local rc=$?
    set -e
    local record="$LOOP_DIR/round-${round}-review-result.md"
    if [[ $rc -eq 0 ]] && grep -qF '[P1]' "$record" 2>/dev/null; then
        pass "$label: the record keeps the marker"
    else
        fail "$label" "return 0 and a record carrying [P1]" \
            "return $rc, record: $(cat "$record" 2>/dev/null || echo none)"
    fi
}

# Ten bare-CR progress updates, then the marker on raw LF line 2 with 49 lines
# after it. The decoded text has 61 lines, the raw bytes 52: the old line
# number pointed past the marker.
{
    printf 'u1\ru2\ru3\ru4\ru5\ru6\ru7\ru8\ru9\ru10\rreview begins\n'
    printf -- '- [P1] CR-shifted finding - f.py:1\n'
    for i in $(seq 1 49); do echo "trailing line $i"; done
} > "$CACHE_DIR/round-80-codex-review.log"
assert_marker_survives 80 "bare-CR progress output"

# A form feed inside an early line: str.splitlines counts it as a line break,
# "\n" does not, so the old tail arithmetic shifted the window by one.
{
    printf 'debug\x0cpage break inside line one\n'
    for i in $(seq 2 41); do echo "line $i"; done
    printf -- '- [P1] FF-shifted finding - f.py:2\n'
    for i in $(seq 43 51); do echo "line $i"; done
} > "$CACHE_DIR/round-81-codex-review.log"
assert_marker_survives 81 "an embedded form feed"

# NEL (U+0085) and the Unicode line separator (U+2028): same class as the form
# feed, different bytes -- str.splitlines cuts on both, "\n" readers on neither.
{
    printf 'status\xc2\x85overwritten status line\n'
    for i in $(seq 2 41); do echo "line $i"; done
    printf -- '- [P1] NEL-shifted finding - f.py:3\n'
    for i in $(seq 43 51); do echo "line $i"; done
} > "$CACHE_DIR/round-82-codex-review.log"
assert_marker_survives 82 "an embedded NEL"

{
    printf 'unicode\xe2\x80\xa8separator inside line one\n'
    for i in $(seq 2 41); do echo "line $i"; done
    printf -- '- [P1] LS-shifted finding - f.py:4\n'
    for i in $(seq 43 51); do echo "line $i"; done
} > "$CACHE_DIR/round-83-codex-review.log"
assert_marker_survives 83 "an embedded U+2028"

# CRLF endings throughout: universal-newline decoding folds them, and the
# published record must still read as exactly one finding.
{
    printf 'review begins\r\n'
    printf -- '- [P1] CRLF finding - f.py:5\r\n'
    printf 'done\r\n'
} > "$CACHE_DIR/round-84-codex-review.log"
assert_marker_survives 84 "CRLF line endings"

# The window itself must be measured in "\n" lines, the unit every other
# reader of this log uses. str.splitlines also cuts on the twenty form feeds
# below, which would shrink the window to fewer real lines and push this
# marker -- on the 50th-to-last "\n" line -- out of it: extraction would go
# blind exactly when the grammar still reads the marker, and the round would
# lose its findings record to the ambiguous path.
{
    echo "review begins"
    printf -- '- [P1] Window-edge finding - f.py:6\n'
    for i in $(seq 1 20); do printf 'noisy\x0cline %s\n' "$i"; done
    for i in $(seq 21 49); do echo "trailing line $i"; done
} > "$CACHE_DIR/round-87-codex-review.log"
assert_marker_survives 87 "a marker at the edge of a form-feed-inflated window"

# What export will read from the CR-shaped record: exactly the finding, not a
# marker-free clean review and not a malformed round. A missing record is a
# fail, not a skip -- that is how this assertion would quietly stop testing.
if [[ ! -f "$LOOP_DIR/round-80-review-result.md" ]]; then
    fail "CR record parse" "a record to parse" "no file written"
else
    RECORD_PARSE=$(cd "$PROJECT_ROOT" && python3 - "$LOOP_DIR/round-80-review-result.md" <<'PY'
import sys
sys.path.insert(0, ".")
from proof.core import parse_review_result

facts = parse_review_result(open(sys.argv[1], encoding="utf-8").read())
print("markers=%d malformed=%d" % (len(facts.markers), len(facts.malformed_markers)))
PY
)
    if [[ "$RECORD_PARSE" == "markers=1 malformed=0" ]]; then
        pass "the CR-shaped record parses as exactly the finding it carries"
    else
        fail "CR record parse" "markers=1 malformed=0" "$RECORD_PARSE"
    fi
fi

# An undecodable log: strict UTF-8 reading fails, so the shared scanner says
# "could not scan". Extraction falls back to the ASCII scan and surfaces the
# finding, but publishes no record -- and with no finding in reach, no
# all-clear is written either.
printf 'ok line\n\xff\xfe undecodable bytes\n- [P1] ASCII finding - f.py:6\nafter\n' \
    > "$CACHE_DIR/round-85-codex-review.log"
set +e
OUTPUT=$(detect_review_issues 85 2>/dev/null)
RESULT=$?
set -e
if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* && ! -f "$LOOP_DIR/round-85-review-result.md" ]]; then
    pass "an undecodable log surfaces findings without publishing a record"
else
    fail "undecodable log with findings" "return 0, [P1] in output, no record" \
        "return $RESULT, record: $(test -f "$LOOP_DIR/round-85-review-result.md" && echo yes || echo no)"
fi

printf 'ok line\n\xff\xfe undecodable bytes\nnothing else here\n' \
    > "$CACHE_DIR/round-86-codex-review.log"
assert_no_clean_record 86 "an undecodable log without findings"

# The same shape under an explicitly UTF-8 locale -- the environment CI's
# macOS runners run in, where BSD awk aborts with "towc: multibyte conversion
# failure" on the first invalid byte unless the fallback pins LC_ALL=C. A
# C-locale shell passed this while the UTF-8 runner silently lost the finding
# and finalized, so the byte scan must not depend on the locale the hook
# happened to inherit.
printf 'ok line\n\xff\xfe undecodable bytes\n- [P1] ASCII finding - f.py:7\nafter\n' \
    > "$CACHE_DIR/round-88-codex-review.log"
set +e
OUTPUT=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 detect_review_issues 88 2>/dev/null)
RESULT=$?
set -e
if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* && ! -f "$LOOP_DIR/round-88-review-result.md" ]]; then
    pass "the fallback survives a UTF-8 locale on undecodable bytes"
else
    fail "fallback locale independence" "return 0, [P1] in output, no record" \
        "return $RESULT, record: $(test -f "$LOOP_DIR/round-88-review-result.md" && echo yes || echo no)"
fi

# The gate side of the same separators, through the parity harness: a marker
# hidden behind CR or FF arithmetic must still withhold the all-clear when it
# sits outside the extraction window.
{
    printf 'u1\ru2\ru3\rreview begins\n'
    printf -- '- [P1] CR-prefixed, out of window - f.py:1\n'
    for i in $(seq 1 60); do echo "trailing line $i"; done
} > "$TEST_DIR/cr-out-of-window.log"
assert_gate_parity "bare-CR log with the marker outside the window" "$TEST_DIR/cr-out-of-window.log"

{
    printf 'debug\x0cpage break\n'
    printf -- '- [P1] FF-prefixed, out of window - f.py:1\n'
    for i in $(seq 1 60); do echo "trailing line $i"; done
} > "$TEST_DIR/ff-out-of-window.log"
assert_gate_parity "form-feed log with the marker outside the window" "$TEST_DIR/ff-out-of-window.log"

# ========================================
# Test 3i: A record is published only after it re-reads as what it claims
# ========================================
# Four false-green paths in a row were each some reader disagreeing with some
# writer about the same bytes -- window, column, byte offset, line break. The
# publish gate closes the shape rather than the instances: before the rename,
# the written bytes go back through the authoritative grammar, and a record
# that no longer reads as what it claims -- whatever future bug produces that
# -- is withheld. These doubles simulate exactly such a divergence.
echo "Test 3i: publish-time re-scan fails closed on writer/reader divergence"

setup_test_env

# A scanner whose extraction emits marker-free text: the re-scan must refuse
# to publish it. The caller still sees the content and the loop continues; the
# round simply gets no record, and a missing record resolves nothing.
cat > "$TEST_DIR/lying-extractor.py" <<'PY'
import sys

if "--extract" in sys.argv:
    sys.stdout.write("a suffix the grammar cannot read as a finding\n")
    raise SystemExit(0)
raise SystemExit(1)
PY
printf -- '- [P1] Real finding - f.py:1\n' > "$CACHE_DIR/round-90-codex-review.log"
SAVED_SCANNER="$REVIEW_MARKER_SCANNER"
REVIEW_MARKER_SCANNER="$TEST_DIR/lying-extractor.py"
set +e
detect_review_issues 90 >/dev/null 2>&1
RESULT=$?
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if [[ $RESULT -eq 0 && ! -f "$LOOP_DIR/round-90-review-result.md" ]]; then
    pass "a marker-free extraction is not published as a findings record"
else
    fail "extraction re-scan" "return 0 and no record" \
        "return $RESULT, record: $(test -f "$LOOP_DIR/round-90-review-result.md" && echo yes || echo no)"
fi

# A scanner that reads the log as clean but the written all-clear as carrying
# a marker -- the shape a wording drift in the record would take.
cat > "$TEST_DIR/drifting-reader.py" <<'PY'
import sys

raise SystemExit(1 if sys.argv[1].endswith(".log") else 0)
PY
printf 'Code review complete\nNothing to report\n' > "$CACHE_DIR/round-91-codex-review.log"
REVIEW_MARKER_SCANNER="$TEST_DIR/drifting-reader.py"
set +e
detect_review_issues 91 >/dev/null 2>&1
RESULT=$?
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if [[ $RESULT -eq 1 && ! -f "$LOOP_DIR/round-91-review-result.md" ]]; then
    pass "an all-clear that re-reads as marker-bearing is withheld"
else
    fail "all-clear re-scan" "return 1 and no record" \
        "return $RESULT, record: $(test -f "$LOOP_DIR/round-91-review-result.md" && echo yes || echo no)"
fi

# The all-clear must satisfy the raw-byte probe that will classify it on the
# next attempt, not only the grammar. An interpolated identity value carrying
# "[P" -- unreachable through git-validated inputs, pinned here by overriding
# the optional global directly -- would read clean to the grammar (the token
# sits past column 10) yet be retained as a findings record by the probe,
# outliving the attempt it belongs to. Publish requires both classifiers to
# agree.
printf 'Code review complete\nNothing to report\n' > "$CACHE_DIR/round-92-codex-review.log"
CODEX_REVIEWED_BASE='release [P1 hotfix'
set +e
detect_review_issues 92 >/dev/null 2>&1
RESULT=$?
set -e
unset CODEX_REVIEWED_BASE
if [[ $RESULT -eq 1 && ! -f "$LOOP_DIR/round-92-review-result.md" ]]; then
    pass "an all-clear carrying raw [P bytes is withheld"
else
    fail "all-clear byte probe" "return 1 and no record" \
        "return $RESULT, record: $(cat "$LOOP_DIR/round-92-review-result.md" 2>/dev/null || echo none)"
fi
set +e
detect_review_issues 92 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-92-review-result.md" ]]; then
    pass "and is published once the identity values are clean"
else
    fail "byte probe control" "a record" "no record written"
fi

# ========================================
# Test 3j: A stale all-clear never outlives the attempt, scanner or no scanner
# ========================================
# The retry that most needs the invalidation is exactly the one whose scanner
# cannot run: the old code re-scanned the existing record to decide whether to
# delete it, so no scanner meant no deletion, and the caller finalized against
# an all-clear nobody had re-established -- which export then parses as a clean
# re-review that resolves pre-existing findings. Deciding with raw bytes makes
# the invalidation unconditional: an all-clear carries no "[P" and is dropped
# up front; a findings record always carries one and never is.
echo "Test 3j: stale records across scanner availability"

setup_test_env

# (a) A clean pass earns the all-clear; the retry finds a marker outside the
# fallback's reach while the scanner is down. The stale all-clear must go.
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-100-codex-review.log"
set +e
detect_review_issues 100 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-100-review-result.md" ]]; then
    pass "setup: the clean pass earned its all-clear"
else
    fail "setup" "an all-clear on disk" "no record written"
fi
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf -- '- [P1] Reported on the retry, outside the window - f.py:1\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-100-codex-review.log"
SAVED_SCANNER="$REVIEW_MARKER_SCANNER"
REVIEW_MARKER_SCANNER="$TEST_DIR/no-such-scanner.py"
set +e
detect_review_issues 100 >/dev/null 2>&1
RESULT=$?
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if [[ $RESULT -eq 1 && ! -f "$LOOP_DIR/round-100-review-result.md" ]]; then
    pass "the stale all-clear is dropped even with the scanner down"
else
    fail "stale all-clear x scanner down" "return 1 and no record" \
        "return $RESULT, record: $(test -f "$LOOP_DIR/round-100-review-result.md" && echo yes || echo no)"
fi

# (b) ...and the same round re-earns a fresh all-clear once the scanner is
# back and the log is genuinely clean again, so (a) is about staleness, not
# about all-clears in general.
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-100-codex-review.log"
set +e
detect_review_issues 100 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-100-review-result.md" ]]; then
    pass "a later established clean pass re-earns the record"
else
    fail "re-established all-clear" "a record" "no record written"
fi

# (c) A findings record survives the scanner-down ambiguous retry: it carries
# "[P" and the byte probe keeps it.
printf 'review output\n- [P1] Genuine finding - f.py:1\n' \
    > "$CACHE_DIR/round-101-codex-review.log"
set +e
detect_review_issues 101 >/dev/null 2>&1
set -e
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf -- '- [P2] Different marker, out of window - f.py:1\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-101-codex-review.log"
REVIEW_MARKER_SCANNER="$TEST_DIR/no-such-scanner.py"
set +e
detect_review_issues 101 >/dev/null 2>&1
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if grep -qF '[P1]' "$LOOP_DIR/round-101-review-result.md" 2>/dev/null; then
    pass "a findings record survives the scanner-down retry"
else
    fail "findings record x scanner down" "the [P1] record preserved" \
        "$(cat "$LOOP_DIR/round-101-review-result.md" 2>/dev/null || echo deleted)"
fi

# (d) The Test 3e collision under an unavailable scanner: an extracted record
# containing the literal all-clear line still carries its marker, so the byte
# probe keeps it too. "Result: clean" decides nothing on this path either.
printf 'scanning\n- [P1] Genuine finding - f.py:1-2\n%s\n' \
    "$CLEAN_REVIEW_MARKER" > "$CACHE_DIR/round-102-codex-review.log"
set +e
detect_review_issues 102 >/dev/null 2>&1
set -e
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf -- '- [P10] ambiguous token, out of window - f.py:1\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-102-codex-review.log"
REVIEW_MARKER_SCANNER="$TEST_DIR/no-such-scanner.py"
set +e
detect_review_issues 102 >/dev/null 2>&1
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if grep -qF '[P1]' "$LOOP_DIR/round-102-review-result.md" 2>/dev/null; then
    pass "the Result-clean collision record survives the scanner-down retry"
else
    fail "collision x scanner down" "the [P1] record preserved" \
        "$(cat "$LOOP_DIR/round-102-review-result.md" 2>/dev/null || echo deleted)"
fi

# (e) The scanner-down fallback surfaces ASCII findings to the caller but
# publishes no record: publishing is an assertion, and the grammar that must
# re-verify every assertion is exactly what is unavailable.
printf 'review output\n- [P1] Fallback-visible finding - f.py:1\n' \
    > "$CACHE_DIR/round-103-codex-review.log"
REVIEW_MARKER_SCANNER="$TEST_DIR/no-such-scanner.py"
set +e
OUTPUT=$(detect_review_issues 103 2>/dev/null)
RESULT=$?
set -e
REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* && ! -f "$LOOP_DIR/round-103-review-result.md" ]]; then
    pass "the fallback surfaces findings without publishing a record"
else
    fail "fallback publish" "return 0, [P1] in output, no record" \
        "return $RESULT, record: $(test -f "$LOOP_DIR/round-103-review-result.md" && echo yes || echo no)"
fi

# (f) An all-clear the attempt cannot remove is a hard failure, not a pass.
# "Dropped the previous all-clear" is itself an assertion; if the unlink did
# not happen, saying it did lets a later ambiguous return of 1 finalize
# against the very record the invalidation exists to remove. A read-only Run
# directory pins the shape: exit 2, the stale record untouched, no claim it
# was dropped -- and an earlier round's findings record rides through intact,
# because a failed invalidation resolves nothing.
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-105-codex-review.log"
set +e
detect_review_issues 105 >/dev/null 2>&1
set -e
printf -- '- [P1] Earlier genuine finding - f.py:1-2\n' \
    > "$LOOP_DIR/round-104-review-result.md"
{
    for i in $(seq 1 4); do echo "Debug line $i"; done
    printf -- '- [P1] Reported on the retry, outside the window - f.py:1\n'
    for i in $(seq 6 70); do echo "More output line $i"; done
} > "$CACHE_DIR/round-105-codex-review.log"
if [[ -f "$LOOP_DIR/round-105-review-result.md" ]]; then
    chmod -w "$LOOP_DIR"
    set +e
    RO_ERR=$(detect_review_issues 105 2>&1 >/dev/null)
    RESULT=$?
    set -e
    chmod +w "$LOOP_DIR"
    if [[ $RESULT -eq 2 ]] && [[ -f "$LOOP_DIR/round-105-review-result.md" ]] && \
       [[ "$RO_ERR" != *"Dropped the previous all-clear"* ]] && \
       grep -qF '[P1]' "$LOOP_DIR/round-104-review-result.md"; then
        pass "an all-clear that cannot be invalidated is a hard failure"
    else
        fail "read-only invalidation" \
            "return 2, stale record present, no drop claim, earlier finding intact" \
            "return $RESULT, stderr: $RO_ERR"
    fi
else
    fail "read-only invalidation setup" "an all-clear on disk" "no record written"
fi

# (g) A record the byte probe cannot read at all is the remaining cell of the
# classification table, and it used to fail open: probe status above 1 fell
# through, the stale all-clear stayed, a scanner-down retry returned 1, and
# the caller finalized -- with the record parseable again the moment its
# permissions came back. Unclassifiable now means preserved AND blocking:
# deleting might destroy a findings record, proceeding lets an assertion
# nobody could read authorize the round. The record must ride through
# byte-for-byte, and stderr must claim classification failed, not that the
# record was dropped.
printf 'Code review complete\nNothing to report\n' \
    > "$CACHE_DIR/round-106-codex-review.log"
set +e
detect_review_issues 106 >/dev/null 2>&1
set -e
if [[ -f "$LOOP_DIR/round-106-review-result.md" ]]; then
    cp "$LOOP_DIR/round-106-review-result.md" "$TEST_DIR/round-106-record-copy.md"
    printf 'retry attempt with nothing the fallback can see\n' \
        > "$CACHE_DIR/round-106-codex-review.log"
    chmod 000 "$LOOP_DIR/round-106-review-result.md"
    REVIEW_MARKER_SCANNER="$TEST_DIR/no-such-scanner.py"
    set +e
    PROBE_ERR=$(detect_review_issues 106 2>&1 >/dev/null)
    RESULT=$?
    set -e
    REVIEW_MARKER_SCANNER="$SAVED_SCANNER"
    chmod 644 "$LOOP_DIR/round-106-review-result.md"
    if [[ $RESULT -eq 2 ]] && \
       cmp -s "$LOOP_DIR/round-106-review-result.md" "$TEST_DIR/round-106-record-copy.md" && \
       [[ "$PROBE_ERR" == *"could not classify the previous review record"* ]] && \
       [[ "$PROBE_ERR" != *"Dropped the previous all-clear"* ]]; then
        pass "an unclassifiable record is preserved and blocks the attempt"
    else
        fail "unclassifiable record" \
            "return 2, record byte-identical, classification error, no drop claim" \
            "return $RESULT, identical: $(cmp -s "$LOOP_DIR/round-106-review-result.md" "$TEST_DIR/round-106-record-copy.md" && echo yes || echo no), stderr: $PROBE_ERR"
    fi
else
    fail "unclassifiable record setup" "an all-clear on disk" "no record written"
fi

# The end-to-end half of (g): status 2 maps to block_review_failure in the
# caller, never enter_finalize_phase, so the blocked attempt leaves the Run
# active -- no finalize or terminal state is written -- and an active Run is
# exactly what export refuses to touch. The unclassifiable record therefore
# cannot reach a verdict at all, let alone authorize accept.
if command -v python3 >/dev/null 2>&1; then
    ACTIVE_RUN="$TEST_DIR/active-run"
    rm -rf "$ACTIVE_RUN"
    cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-rereview-derived" "$ACTIVE_RUN"
    mv "$ACTIVE_RUN/complete-state.md" "$ACTIVE_RUN/state.md"
    mkdir -p "$TEST_DIR/active-bundle"
    set +e
    ACTIVE_OUT=$(bash -c "
        source '$PROJECT_ROOT/scripts/loop.sh'
        loop proof export --run '$ACTIVE_RUN' --out '$TEST_DIR/active-bundle'
    " 2>&1)
    ACTIVE_RC=$?
    set -e
    if [[ $ACTIVE_RC -ne 0 ]] && [[ ! -f "$TEST_DIR/active-bundle/proof.json" ]]; then
        pass "an active Run is refused by export, so a blocked attempt cannot reach a verdict"
    else
        fail "active-run export refusal" "a refusal and no bundle" \
            "exit $ACTIVE_RC, bundle: $(test -f "$TEST_DIR/active-bundle/proof.json" && echo yes || echo no), output: $(echo "$ACTIVE_OUT" | head -2)"
    fi
else
    pass "active-run export refusal skipped (python3 unavailable)"
fi

# ========================================
# Test 3k: End to end -- a poisoned log cannot resolve a real finding
# ========================================
# The chain in one pass, on a real Run: a review log that still reports a
# finding, mangled by the exact CR shape that used to shift extraction, must
# leave export unable to resolve that finding or to derive accept. Uses the
# clean-rereview-derived fixture, whose round-1 review reports the finding and
# whose round-2 record is what normally resolves it.
echo "Test 3k: export cannot resolve a finding the poisoned log still reports"

if ! command -v python3 >/dev/null 2>&1; then
    pass "end-to-end export skipped (python3 unavailable)"
else
    E2E_RUN="$TEST_DIR/e2e-run"
    rm -rf "$E2E_RUN"
    cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-rereview-derived" "$E2E_RUN"
    P1_LINE=$(grep '^- \[P1\]' "$E2E_RUN/round-1-review-result.md" | head -1)
    rm -f "$E2E_RUN/round-2-review-result.md"

    E2E_CACHE="$TEST_DIR/e2e-cache"
    mkdir -p "$E2E_CACHE"
    {
        printf 'u1\ru2\ru3\ru4\ru5\ru6\ru7\ru8\ru9\ru10\rre-review begins\n'
        printf '%s\n' "$P1_LINE"
        for i in $(seq 1 49); do echo "trailing line $i"; done
    } > "$E2E_CACHE/round-2-codex-review.log"

    SAVED_LOOP_DIR="$LOOP_DIR"
    SAVED_CACHE_DIR="$CACHE_DIR"
    LOOP_DIR="$E2E_RUN"
    CACHE_DIR="$E2E_CACHE"
    set +e
    detect_review_issues 2 >/dev/null 2>&1
    E2E_RC=$?
    set -e
    LOOP_DIR="$SAVED_LOOP_DIR"
    CACHE_DIR="$SAVED_CACHE_DIR"

    if [[ $E2E_RC -eq 0 ]] && grep -qF '[P1]' "$E2E_RUN/round-2-review-result.md" 2>/dev/null; then
        pass "the poisoned log's record still carries the re-reported [P1]"
    else
        fail "e2e record" "return 0 and a [P1]-carrying round-2 record" \
            "return $E2E_RC, record: $(head -3 "$E2E_RUN/round-2-review-result.md" 2>/dev/null || echo none)"
    fi

    E2E_BUNDLE="$TEST_DIR/e2e-bundle"
    mkdir -p "$E2E_BUNDLE"
    if bash -c "
        source '$PROJECT_ROOT/scripts/loop.sh'
        loop proof export --run '$E2E_RUN' --profile local-v0 --out '$E2E_BUNDLE'
    " >/dev/null 2>&1; then
        E2E_VERDICT=$(python3 - "$E2E_BUNDLE/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
decision = bundle.get("verdict", {}).get("decision", "")
p1_statuses = sorted(
    finding.get("status", "")
    for finding in bundle.get("findings", [])
    if finding.get("severity") == "P1"
)
print("%s:%s" % (decision, ",".join(p1_statuses)))
PY
)
        case "$E2E_VERDICT" in
            accept:*|*resolved*)
                fail "e2e verdict" "no accept, no resolved P1" "$E2E_VERDICT" ;;
            *open*)
                pass "export keeps the P1 open and does not derive accept ($E2E_VERDICT)" ;;
            *)
                fail "e2e verdict" "a P1 finding left open" "$E2E_VERDICT" ;;
        esac
    else
        fail "e2e export" "an exported bundle" "export did not produce a bundle"
    fi
fi

# ========================================
# Test 4: Missing log file - should return 2
# ========================================
echo "Test 4: detect_review_issues returns error code 2 when log file is missing"
setup_test_env

rm -f "$CACHE_DIR/round-4-codex-review.log" 2>/dev/null || true

set +e
OUTPUT=$(detect_review_issues 4 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 2 ]]; then
    pass "Missing log file returns 2 (hard error)"
else
    fail "Missing log file handling" "return 2 (hard error)" "return $RESULT"
fi

# ========================================
# Test 5: Empty log file - should return 2
# ========================================
echo "Test 5: detect_review_issues returns error code 2 when log file is empty"
setup_test_env

touch "$CACHE_DIR/round-5-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 5 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 2 ]]; then
    pass "Empty log file returns 2 (hard error)"
else
    fail "Empty log file handling" "return 2 (hard error)" "return $RESULT"
fi

# ========================================
# Test 6: Log file with >50 lines, [P?] late in file
# ========================================
echo "Test 6: detect_review_issues finds [P?] late in a long log"
setup_test_env

# Create a log file with 60 lines, [P1] at line 55
{
    for i in $(seq 1 54); do
        echo "Debug line $i - some processing output"
    done
    echo "- [P1] Bug found in the code - /path/to/file.py:100"
    for i in $(seq 56 60); do
        echo "More output line $i"
    done
} > "$CACHE_DIR/round-6-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 6 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* ]]; then
    pass "[P?] found late in long log"
else
    fail "[P?] late in long log" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 7: Log file with >50 lines, [P?] early in file - should NOT detect
# ========================================
echo "Test 7: detect_review_issues ignores [P?] early in a long log (outside last 50 lines)"
setup_test_env

# Create a log file with 70 lines, [P1] at line 5 (early in the file)
# Since we only scan the last 50 lines, line 5 of 70 is outside the window
{
    for i in $(seq 1 4); do
        echo "Debug line $i"
    done
    echo "- [P1] This is early in the file - /path/to/file.py:1"
    for i in $(seq 6 70); do
        echo "More output line $i - no issues here"
    done
} > "$CACHE_DIR/round-7-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 7 2>/dev/null)
RESULT=$?
set -e

# [P1] is at line 5 of 70 - outside the last-50-line window, should return 1
if [[ $RESULT -eq 1 ]]; then
    pass "[P?] early in file ignored (outside last 50 lines)"
else
    fail "[P?] early in file" "return 1 (no issues)" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 8: Multiple [P?] lines - first one is the start of extraction
# ========================================
echo "Test 8: detect_review_issues extracts from first [P?] line to end"
setup_test_env

cat > "$CACHE_DIR/round-8-codex-review.log" << 'EOF'
Debug output line 1
Debug output line 2
- [P0] Critical issue - /path/to/critical.py:10
  This is a critical bug.
- [P2] Minor issue - /path/to/minor.py:20
  This is a minor issue.
Final debug line
EOF

set +e
OUTPUT=$(detect_review_issues 8 2>/dev/null)
RESULT=$?
set -e

# Should extract from [P0] line to the end, including [P2] and final line
if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P0]'* && "$OUTPUT" == *'[P2]'* && "$OUTPUT" == *"Final debug"* ]]; then
    pass "Extraction from first [P?] to end works"
else
    fail "Multi-issue extraction" "return 0, contains [P0], [P2], and final line" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 9: [P?] exactly at position 0 (first char)
# ========================================
echo "Test 9: detect_review_issues finds [P?] at very start of line"
setup_test_env

cat > "$CACHE_DIR/round-9-codex-review.log" << 'EOF'
Debug output
[P3] Issue at start of line - /path/to/file.py:5
  Description of the issue.
EOF

set +e
OUTPUT=$(detect_review_issues 9 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P3]'* ]]; then
    pass "[P?] at position 0 detected"
else
    fail "[P?] at position 0" "return 0, output contains [P3]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 10: [P?] with dash prefix (common format)
# ========================================
echo "Test 10: detect_review_issues finds [P?] with dash prefix"
setup_test_env

cat > "$CACHE_DIR/round-10-codex-review.log" << 'EOF'
Review started
Analyzing files...
- [P1] Security vulnerability - /path/to/auth.py:50
  Password stored in plain text.
EOF

set +e
OUTPUT=$(detect_review_issues 10 2>/dev/null)
RESULT=$?
set -e

# "- [P1]" - the [P1] starts at position 2, which is within first 10 chars
if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* ]]; then
    pass "[P?] with dash prefix detected"
else
    fail "[P?] with dash prefix" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 11: Result file is created when issues found
# ========================================
echo "Test 11: detect_review_issues creates result file when issues found"
setup_test_env

cat > "$CACHE_DIR/round-11-codex-review.log" << 'EOF'
Debug line
- [P2] Test issue - /file.py:1
  Issue description
EOF

# Ensure result file doesn't exist
rm -f "$LOOP_DIR/round-11-review-result.md" 2>/dev/null || true

set +e
OUTPUT=$(detect_review_issues 11 2>/dev/null)
RESULT=$?
set -e

# Check that result file was created
if [[ $RESULT -eq 0 ]] && [[ -f "$LOOP_DIR/round-11-review-result.md" ]]; then
    pass "Result file created when issues found"
else
    fail "Result file creation" "return 0, result file exists" "return $RESULT, file exists: $(test -f "$LOOP_DIR/round-11-review-result.md" && echo yes || echo no)"
fi

# ========================================
# Test 12: Exactly 50 lines, [P?] on line 1
# ========================================
echo "Test 12: detect_review_issues handles exactly 50 lines"
setup_test_env

{
    echo "- [P1] First line issue - /file.py:1"
    for i in $(seq 2 50); do
        echo "Line $i content"
    done
} > "$CACHE_DIR/round-12-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 12 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 && "$OUTPUT" == *'[P1]'* ]]; then
    pass "Exactly 50 lines handled correctly"
else
    fail "Exactly 50 lines" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================="
echo "Test Results"
echo "========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
