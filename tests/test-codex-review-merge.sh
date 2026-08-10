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

# Setup test environment
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

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
