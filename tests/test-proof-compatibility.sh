#!/usr/bin/env bash
# Compatibility coverage: terminal states, legacy Runs, and the verify contract.
#
# These reason codes were all implemented and none of them asserted, so nothing
# stopped a refactor from dropping a warning and leaving the Bundle looking
# clean: `legacy-version-gap`, `duplicate-evidence-id` and `truncated-evidence`
# had zero references anywhere under tests/.
#
# The exit-code contract in docs/proof-of-loop-mvp-spec.md section J is the
# other half: a reason is only useful if it maps to the documented exit status,
# so each scenario asserts the pair rather than the reason alone.

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

assert_equals() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "$expected" "$actual"
    fi
}

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "Proof compatibility tests require Python 3.9 or newer." >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

echo "========================================"
echo "Proof Compatibility Tests"
echo "========================================"

make_run() {
    local name="$1"
    local fixture="$2"
    local project="$TEST_DIR/$name"
    local run_dir="$project/.loop/rlcr/2026-07-29_20-22-19"
    mkdir -p "$project/.loop/rlcr"
    cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/$fixture" "$run_dir"
    git -C "$project" init -q
    git -C "$project" config user.email proof-test@example.invalid
    git -C "$project" config user.name 'Proof Test'
    git -C "$project" config commit.gpgsign false
    printf 'fixture project\n' > "$project/README.md"
    git -C "$project" add README.md
    git -C "$project" commit -q -m 'fixture project'
    printf '%s' "$run_dir"
}

export_run() {
    local run_dir="$1"
    local out="$TEST_DIR/bundles/$2"
    local profile="${3:-local-v0}"
    mkdir -p "$out"
    if bash -c "
        source '$PROJECT_ROOT/scripts/loop.sh'
        loop proof export --run '$run_dir' --profile '$profile' --out '$out'
    " >/dev/null 2>&1; then
        printf '%s' "$out"
    fi
}

# Run verify and report "<exit>|<status>" so the exit code and the reported
# status are always asserted together.
verify_run() {
    local bundle="$1"
    local output
    local status
    output=$(bash -c "
        source '$PROJECT_ROOT/scripts/loop.sh'
        loop proof verify '$bundle'
    " 2>&1)
    status=$?
    printf '%s|%s' "$status" "$(printf '%s' "$output" | sed -n 's/^status: //p' | head -1)"
}

# Collect the reason codes verify reports. Failing reasons print as
# "<reason>: <target>" and non-failing ones as "warning <reason>: <target>", so
# both forms are read; the leading "status:" line is not a reason.
verify_reasons() {
    bash -c "
        source '$PROJECT_ROOT/scripts/loop.sh'
        loop proof verify '$1'
    " 2>&1 \
        | sed -n -e 's/^warning \([a-z][a-z-]*\):.*/\1/p' -e 's/^\([a-z][a-z-]*\):.*/\1/p' \
        | grep -v '^status$' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# Apply a mutation to a Bundle's proof.json and recompute its proof_id, so the
# only thing wrong with the result is the mutation.
#
# Without the recomputation every tamper case fails as `proof-id-mismatch`,
# which makes the assertion pass no matter what the check under test does --
# that mistake made an earlier version of the lifecycle-link test vacuous.
#
# The hash is recomputed here with hashlib rather than by importing
# proof.contract, because the spec's Testing Decisions keep the CLI subprocess
# as the only seam these suites touch. tests/test-proof-verify.sh recomputes it
# the same way.
#
# Usage: rehash_bundle <proof.json> <<'PY'
#        <python statements mutating the `bundle` dict>
#        PY
rehash_bundle() {
    local path="$1"
    local mutation
    mutation=$(cat)
    python3 - "$path" "$mutation" <<'PY'
import hashlib
import json
import sys

path, mutation = sys.argv[1], sys.argv[2]
bundle = json.load(open(path, encoding="utf-8"))
exec(mutation, {"bundle": bundle})
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
).hexdigest()
json.dump(bundle, open(path, "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)
PY
}

warnings_of() {
    python3 - "$1" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1] + "/proof.json", encoding="utf-8"))
print(
    ",".join(
        sorted({warning["reason"] for warning in bundle["integrity"]["compile_warnings"]})
    )
)
PY
}

# ========================================
# Terminal states
# ========================================

echo ""
echo "Section 1: Every terminal state exports (AC-1)"

# The five terminal states a Run can end in. All five must export; a state the
# compiler cannot classify is the failure this guards against.
for pair in \
    "clean-complete:complete" \
    "cancel-after-review:cancel" \
    "maxiter-derived:maxiter" \
    "stop-derived:stop" \
    "unexpected-derived:unexpected"
do
    fixture="${pair%%:*}"
    expected_state="${pair##*:}"
    state_run=$(make_run "state-$fixture" "$fixture")
    state_bundle=$(export_run "$state_run" "state-$fixture")
    if [[ -n "$state_bundle" ]]; then
        actual_state=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))['run']['terminal_state'])
" "$state_bundle")
        assert_equals "$fixture exports with terminal state $expected_state" \
            "$expected_state" "$actual_state"
    else
        fail "$fixture export" "a bundle" "export failed"
    fi
done

# ========================================
# Legacy Runs
# ========================================

echo ""
echo "Section 2: A pre-Recorder Run degrades without crashing"

LEGACY_RUN=$(make_run legacy legacy-pre-d17)
LEGACY_BUNDLE=$(export_run "$LEGACY_RUN" legacy)
if [[ -n "$LEGACY_BUNDLE" ]]; then
    LEGACY_WARNINGS=$(warnings_of "$LEGACY_BUNDLE")
    if [[ "$LEGACY_WARNINGS" == *legacy-version-gap* ]]; then
        pass "a Run without Recorder facts warns legacy-version-gap"
    else
        fail "legacy-version-gap" "the warning" "$LEGACY_WARNINGS"
    fi

    # head_commit and reviewed_commit stay null rather than being guessed, and
    # the run_id is still deterministic over those nulls.
    LEGACY_COMMITS=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
source = bundle['source']
print('%s|%s' % (source.get('head_commit'), source.get('reviewed_commit')))
" "$LEGACY_BUNDLE")
    assert_equals "unrecorded commits stay null instead of being inferred" "None|None" \
        "$LEGACY_COMMITS"

    LEGACY_RUN_ID=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))['run_id'])
" "$LEGACY_BUNDLE")
    LEGACY_RUN_TWO=$(make_run legacy-again legacy-pre-d17)
    LEGACY_BUNDLE_TWO=$(export_run "$LEGACY_RUN_TWO" legacy-again)
    LEGACY_RUN_ID_TWO=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))['run_id'])
" "$LEGACY_BUNDLE_TWO")
    assert_equals "the null-based run_id is deterministic" "$LEGACY_RUN_ID" "$LEGACY_RUN_ID_TWO"

    # A legacy Run cannot earn the badge: integrity is incomplete, which is one
    # of the badge's four conditions.
    LEGACY_INTEGRITY=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))['integrity']['status'])
" "$LEGACY_BUNDLE")
    assert_equals "a legacy Run cannot be badged (integrity is not valid)" "incomplete" \
        "$LEGACY_INTEGRITY"
    assert_equals "verify reports incomplete with exit 2" "2|incomplete" \
        "$(verify_run "$LEGACY_BUNDLE")"
else
    fail "legacy export" "a bundle" "export failed"
fi

# ========================================
# Oversized evidence
# ========================================

echo ""
echo "Section 3: Oversized evidence is truncated, not silently dropped"

TRUNCATED_RUN=$(make_run truncated clean-complete)
# max_item_bytes is 1 MiB in both shipped profiles.
python3 -c "
import sys
open(sys.argv[1], 'w', encoding='utf-8').write('# Padded summary\n' + 'x' * 1200000 + '\n')
" "$TRUNCATED_RUN/round-0-summary.md"
TRUNCATED_SHA=$(python3 -c "
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
" "$TRUNCATED_RUN/round-0-summary.md")
TRUNCATED_SIZE=$(python3 -c "
import os, sys
print(os.path.getsize(sys.argv[1]))
" "$TRUNCATED_RUN/round-0-summary.md")

TRUNCATED_BUNDLE=$(export_run "$TRUNCATED_RUN" truncated)
if [[ -n "$TRUNCATED_BUNDLE" ]]; then
    TRUNCATED_WARNINGS=$(warnings_of "$TRUNCATED_BUNDLE")
    if [[ "$TRUNCATED_WARNINGS" == *truncated-evidence* ]]; then
        pass "an oversized item warns truncated-evidence"
    else
        fail "truncated-evidence" "the warning" "$TRUNCATED_WARNINGS"
    fi

    # The hash and byte count describe the source file, not the withheld
    # payload, so a reader can still tell what was left out and check it
    # against the original.
    TRUNCATED_ITEM=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
item = next(i for i in bundle['evidence'] if i['path'] == 'round-0-summary.md')
print('%s|%s|%s|%s' % (item['status'], item['sha256'], item['bytes'], item['omitted_reason']))
" "$TRUNCATED_BUNDLE")
    assert_equals "the item keeps status, original hash, byte count and reason" \
        "truncated|$TRUNCATED_SHA|$TRUNCATED_SIZE|size-limit" "$TRUNCATED_ITEM"

    # The oversized bytes must not be in the Bundle at all.
    if [[ ! -f "$TRUNCATED_BUNDLE/evidence/round-0-summary.md" ]]; then
        pass "truncated evidence bytes are not written into the Bundle"
    else
        fail "truncated evidence bytes" "no evidence file" "the file was written"
    fi

    assert_equals "verify reports truncation as incomplete with exit 2" "2|incomplete" \
        "$(verify_run "$TRUNCATED_BUNDLE")"
    TRUNCATED_REASONS=$(verify_reasons "$TRUNCATED_BUNDLE")
    if [[ "$TRUNCATED_REASONS" == *truncated-evidence* ]]; then
        pass "verify names truncated-evidence as the reason"
    else
        fail "verify truncated reason" "truncated-evidence" "$TRUNCATED_REASONS"
    fi
else
    fail "truncated export" "a bundle" "export failed"
fi

# ========================================
# Verify contract (spec section J)
# ========================================

echo ""
echo "Section 4: Structural damage is invalid, not incomplete"

CLEAN_RUN=$(make_run clean clean-complete)
CLEAN_BUNDLE=$(export_run "$CLEAN_RUN" clean)
assert_equals "a clean Bundle verifies valid with exit 0" "0|valid" \
    "$(verify_run "$CLEAN_BUNDLE")"

# Two evidence entries sharing one ID make every reference to that ID
# ambiguous, so the Bundle is invalid rather than merely incomplete.
DUPLICATE_BUNDLE="$TEST_DIR/bundles/duplicate"
cp -R "$CLEAN_BUNDLE" "$DUPLICATE_BUNDLE"
python3 - "$DUPLICATE_BUNDLE/proof.json" <<'PY'
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
first, second = bundle["evidence"][0], bundle["evidence"][1]
second["id"] = first["id"]
json.dump(bundle, open(path, "w", encoding="utf-8"))
PY
DUPLICATE_RESULT=$(verify_run "$DUPLICATE_BUNDLE")
assert_equals "a duplicate evidence ID is invalid with exit 3" "3|invalid" "$DUPLICATE_RESULT"
DUPLICATE_REASONS=$(verify_reasons "$DUPLICATE_BUNDLE")
if [[ "$DUPLICATE_REASONS" == *duplicate-evidence-id* ]]; then
    pass "verify names duplicate-evidence-id"
else
    fail "duplicate-evidence-id reason" "duplicate-evidence-id" "$DUPLICATE_REASONS"
fi

# A reference to an evidence ID that is not in the Bundle is equally structural.
DANGLING_BUNDLE="$TEST_DIR/bundles/dangling"
cp -R "$CLEAN_BUNDLE" "$DANGLING_BUNDLE"
python3 - "$DANGLING_BUNDLE/proof.json" <<'PY'
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["verdict"]["per_ac"][0]["supporting"] = ["0123456789abcdef"]
json.dump(bundle, open(path, "w", encoding="utf-8"))
PY
assert_equals "a dangling evidence reference is invalid with exit 3" "3|invalid" \
    "$(verify_run "$DANGLING_BUNDLE")"
DANGLING_REASONS=$(verify_reasons "$DANGLING_BUNDLE")
if [[ "$DANGLING_REASONS" == *dangling-reference* ]]; then
    pass "verify names dangling-reference"
else
    fail "dangling-reference reason" "dangling-reference" "$DANGLING_REASONS"
fi

echo ""
echo "Section 5: Cleared findings must carry the link that justifies them"

# The verifier's job is to check the Bundle, not to take the producer's word
# for it. A hand-edited Bundle that promotes findings to `resolved` or `waived`
# without the corresponding link is claiming a lifecycle it cannot show -- the
# Explorer already refuses to render it as resolved, and verify must agree.
LINK_RUN=$(make_run link clean-complete)
cat > "$LINK_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P1] Handle the empty-string case - greeting.py:6-6
  The helper returns None for an empty input.
REVIEW_EOF
cp "$LINK_RUN/round-0-summary.md" "$LINK_RUN/round-1-summary.md"
cat > "$LINK_RUN/round-1-review-result.md" <<'REVIEW_EOF'
No blocking issues remain.
REVIEW_EOF
LINK_BUNDLE=$(export_run "$LINK_RUN" link)
if [[ -n "$LINK_BUNDLE" ]]; then
    assert_equals "a genuinely resolved finding verifies valid with exit 0" "0|valid" \
        "$(verify_run "$LINK_BUNDLE")"

    # Strip the link but keep the status, and **re-hash**: without that the
    # proof_id no longer matches and `proof-id-mismatch` fails the Bundle for
    # a reason that has nothing to do with the missing link, which would make
    # this assertion pass no matter what the finding check does.
    STRIPPED_BUNDLE="$TEST_DIR/bundles/link-stripped"
    cp -R "$LINK_BUNDLE" "$STRIPPED_BUNDLE"
    rehash_bundle "$STRIPPED_BUNDLE/proof.json" <<'PY'
for finding in bundle["findings"]:
    finding.pop("re_review_ref", None)
PY
    STRIPPED_REASONS=$(verify_reasons "$STRIPPED_BUNDLE")
    if [[ "$STRIPPED_REASONS" != *proof-id-mismatch* ]]; then
        pass "the stripped Bundle re-hashed cleanly, so the link is what is under test"
    else
        fail "stripped Bundle rehash" "no proof-id-mismatch" "$STRIPPED_REASONS"
    fi
    assert_equals "a resolved finding with no re-review link is invalid" "3|invalid" \
        "$(verify_run "$STRIPPED_BUNDLE")"

    # Pointing the link at evidence the Bundle does not include is equally
    # unverifiable.
    DANGLING_LINK_BUNDLE="$TEST_DIR/bundles/link-dangling"
    cp -R "$LINK_BUNDLE" "$DANGLING_LINK_BUNDLE"
    rehash_bundle "$DANGLING_LINK_BUNDLE/proof.json" <<'PY'
for finding in bundle["findings"]:
    if "re_review_ref" in finding:
        finding["re_review_ref"] = "0123456789abcdef"
PY
    assert_equals "a re-review link pointing nowhere is invalid" "3|invalid" \
        "$(verify_run "$DANGLING_LINK_BUNDLE")"

    # A link that resolves to included evidence of the wrong kind is just as
    # unverifiable: a plan cannot substantiate a re-review.
    WRONG_KIND_BUNDLE="$TEST_DIR/bundles/link-wrong-kind"
    cp -R "$LINK_BUNDLE" "$WRONG_KIND_BUNDLE"
    rehash_bundle "$WRONG_KIND_BUNDLE/proof.json" <<'PY'
plan = next(
    item
    for item in bundle["evidence"]
    if item["path"] == "plan.md" and item["status"] == "included"
)
for finding in bundle["findings"]:
    if "re_review_ref" in finding:
        finding["re_review_ref"] = plan["id"]
PY
    assert_equals "a re-review link pointing at the plan is invalid" "3|invalid" \
        "$(verify_run "$WRONG_KIND_BUNDLE")"
else
    fail "link export" "a bundle" "export failed"
fi

echo ""
echo "Section 6: Truncation is derived from the Bundle, not from its own warning"

# The compiler records `truncated-evidence` in compile_warnings, but verify
# must not depend on that: a producer that declares an item truncated and drops
# the warning would otherwise verify `valid`.
# An *optional* evidence kind is used so the Bundle has nothing else wrong with
# it: truncating a required kind would independently produce
# profile-required-evidence-missing and mask whether the truncation check works.
SILENT_RUN=$(make_run silent clean-complete)
python3 -c "
import sys
open(sys.argv[1], 'w', encoding='utf-8').write('# Padded prompt\n' + 'x' * 1200000 + '\n')
" "$SILENT_RUN/round-0-prompt.md"
SILENT_SOURCE=$(export_run "$SILENT_RUN" silent-source)
if [[ -n "$SILENT_SOURCE" ]]; then
    assert_equals "a truncated optional item alone is incomplete with exit 2" "2|incomplete" \
        "$(verify_run "$SILENT_SOURCE")"

    SILENT_BUNDLE="$TEST_DIR/bundles/truncated-silent"
    cp -R "$SILENT_SOURCE" "$SILENT_BUNDLE"
    # Only the warning is removed. Flipping the declared status too would make
    # the Bundle `invalid` on integrity-status-mismatch, which is a different
    # check passing and would hide whether truncation is derived at all.
    rehash_bundle "$SILENT_BUNDLE/proof.json" <<'PY'
integrity = bundle["integrity"]
integrity["compile_warnings"] = [
    warning
    for warning in integrity["compile_warnings"]
    if warning["reason"] != "truncated-evidence"
]
PY
    SILENT_REASONS=$(verify_reasons "$SILENT_BUNDLE")
    if [[ "$SILENT_REASONS" != *proof-id-mismatch* ]]; then
        pass "the silenced Bundle re-hashed cleanly, so truncation is what is under test"
    else
        fail "silenced Bundle rehash" "no proof-id-mismatch" "$SILENT_REASONS"
    fi
    if [[ "$SILENT_REASONS" == *truncated-evidence* ]]; then
        pass "verify derives truncated-evidence without the compiler's warning"
    else
        fail "independent truncation check" "truncated-evidence" "$SILENT_REASONS"
    fi
    assert_equals "and a re-hashed silenced Bundle is still incomplete" "2|incomplete" \
        "$(verify_run "$SILENT_BUNDLE")"

    # Claiming `valid` on top of it is then caught as a status mismatch.
    LYING_BUNDLE="$TEST_DIR/bundles/truncated-lying"
    cp -R "$SILENT_BUNDLE" "$LYING_BUNDLE"
    rehash_bundle "$LYING_BUNDLE/proof.json" <<'PY'
bundle["integrity"]["status"] = "valid"
PY
    assert_equals "declaring it valid is invalid, not accepted" "3|invalid" \
        "$(verify_run "$LYING_BUNDLE")"
else
    fail "silent truncation export" "a bundle" "export failed"
fi

echo ""
echo "Section 7: A reviewed commit behind head withholds the badge (D8)"

# Reviewing an earlier commit than the one delivered is not a defect in the
# Bundle -- the evidence is intact and internally consistent -- so integrity
# stays valid and only the badge condition fails.
BEHIND_RUN=$(make_run behind clean-complete)
BEHIND_PROJECT="$TEST_DIR/behind"
# Both commits have to exist in the repository. A reviewed_commit that git
# cannot resolve is "unknown", which is a different reason code and a different
# integrity state -- the case under test is a resolvable commit that simply is
# not the final head.
BEHIND_REVIEWED=$(git -C "$BEHIND_PROJECT" rev-parse HEAD)
printf 'later work\n' >> "$BEHIND_PROJECT/README.md"
git -C "$BEHIND_PROJECT" add README.md
git -C "$BEHIND_PROJECT" commit -q -m 'work delivered after review'
BEHIND_HEAD=$(git -C "$BEHIND_PROJECT" rev-parse HEAD)
python3 - "$BEHIND_RUN/complete-state.md" "$BEHIND_HEAD" "$BEHIND_REVIEWED" <<'PY'
import re
import sys

path, head, reviewed = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^head_commit:.*$", "head_commit: " + head, text, count=1, flags=re.MULTILINE)
text = re.sub(
    r"^reviewed_commit:.*$", "reviewed_commit: " + reviewed, text, count=1, flags=re.MULTILINE
)
open(path, "w", encoding="utf-8").write(text)
PY

BEHIND_BUNDLE=$(export_run "$BEHIND_RUN" behind)
if [[ -n "$BEHIND_BUNDLE" ]]; then
    BEHIND_STATE=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
source = bundle['source']
print('%s|%s|%s' % (
    bundle['integrity']['status'],
    source.get('head_commit') == source.get('reviewed_commit'),
    ','.join(sorted({w['reason'] for w in bundle['integrity']['compile_warnings']})),
))
" "$BEHIND_BUNDLE")
    BEHIND_INTEGRITY="${BEHIND_STATE%%|*}"
    BEHIND_REST="${BEHIND_STATE#*|}"
    BEHIND_EQUAL="${BEHIND_REST%%|*}"
    BEHIND_REASONS="${BEHIND_REST#*|}"
    assert_equals "integrity stays valid when review is behind head" "valid" "$BEHIND_INTEGRITY"
    assert_equals "the badge condition head == reviewed is false" "False" "$BEHIND_EQUAL"
    if [[ -n "$BEHIND_REASONS" ]]; then
        pass "the mismatch is recorded as a warning ($BEHIND_REASONS)"
    else
        fail "reviewed-behind-head warning" "a recorded warning" "none"
    fi
    assert_equals "and the Bundle still verifies valid with exit 0" "0|valid" \
        "$(verify_run "$BEHIND_BUNDLE")"
else
    fail "behind-head export" "a bundle" "export failed"
fi

echo ""
echo "========================================"
echo "Proof Compatibility Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
echo -e "${RED}Some tests failed!${NC}"
exit 1
