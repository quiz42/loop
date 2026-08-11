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

# `max_item_bytes` in both shipped profiles. Named once because the boundary
# cases below have to agree with each other: one builds a source at exactly the
# cap and another asserts no item is declared truncated at or under it.
MAX_ITEM_BYTES=1048576

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

# Just the exit code from one `loop proof ...` invocation. The usage and
# unreadable-Run paths print nothing a status line can be read from, and the
# exit code is the whole contract for them.
proof_exit() {
    bash -c '
        source "$0"
        loop proof "$@"
    ' "$PROJECT_ROOT/scripts/loop.sh" "$@" >/dev/null 2>&1
    printf '%s' "$?"
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
# `path` is exposed so a mutation can also touch the evidence files next to the
# manifest and re-derive their identities.
exec(mutation, {"bundle": bundle, "path": path})
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

# Rewrite one evidence file's contents and make the Bundle coherent again: new
# digest, new Evidence ID, every reference to the old ID updated, new proof_id.
#
# A Bundle is only a useful tamper case once it is internally coherent -- the
# Evidence ID is derived from path plus digest, so editing a file without this
# fails on the ID rule or a hash mismatch and the assertion passes for a reason
# that has nothing to do with the check under test.
#
# Usage: rewrite_evidence <bundle-dir> <evidence-relative-path> <<'EOF'
#        <new file contents>
#        EOF
rewrite_evidence() {
    local bundle="$1"
    local target="$2"
    cat > "$bundle/evidence/$target"
    python3 - "$bundle/proof.json" "$target" <<'PY'
import hashlib
import json
import os
import sys

manifest_path, target = sys.argv[1], sys.argv[2]
bundle = json.load(open(manifest_path, encoding="utf-8"))
data = open(
    os.path.join(os.path.dirname(manifest_path), "evidence", target), "rb"
).read()
digest = hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


new_id = hashlib.sha256(canonical({"path": target, "sha256": digest})).hexdigest()[:16]
old_id = None
for item in bundle["evidence"]:
    if item["path"] == target:
        old_id = item["id"]
        item["sha256"] = digest
        item["bytes"] = len(data)
        item["id"] = new_id


def swap(node):
    if isinstance(node, list):
        return [swap(child) for child in node]
    if isinstance(node, dict):
        return {key: swap(child) for key, child in node.items()}
    return new_id if node == old_id else node


bundle = swap(bundle)
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(canonical(payload)).hexdigest()
json.dump(
    bundle, open(manifest_path, "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True
)
PY
}

# "<kind>/<status>|<integrity>|<reasons>" for one source path: how the item was
# classified, what it cost the Bundle, and which warnings name that exact file.
# Asserted as one string so a regression that keeps the item but drops the
# warning -- or keeps the warning but stops naming the file -- cannot pass.
# `absent` where the compiler collected no item at all.
item_report_of() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1] + "/proof.json", encoding="utf-8"))
target = sys.argv[2]
item = next((i for i in bundle["evidence"] if i["path"] == target), None)
warnings = [
    w for w in bundle["integrity"]["compile_warnings"] if w.get("target") == target
]
print(
    "%s|%s|%s"
    % (
        "absent" if item is None else "%s/%s" % (item["kind"], item["status"]),
        bundle["integrity"]["status"],
        ",".join(sorted(w["reason"] for w in warnings)),
    )
)
PY
}

# Every compile-warning detail naming one exact source path, joined. AC-10
# wants the conclusion a warning costs, and that lives in the detail rather
# than in the reason code.
warning_detail_of() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1] + "/proof.json", encoding="utf-8"))
print(
    " ".join(
        warning.get("detail", "")
        for warning in bundle["integrity"]["compile_warnings"]
        if warning.get("target") == sys.argv[2]
    )
)
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

    # Determinism does not say what the two exports agreed on. Any fabricated
    # substitute for the unrecorded head_commit is equally deterministic, and
    # `run.head_commit or "unrecorded"` kept all five suites green while
    # silently changing legacy Run identity. The golden pins the payload as the
    # null-based one: sha256 over {"algo":"run-id-v0","base_commit":"2ab7053...",
    # "head_commit":null,"round_indices":[0],"session_timestamp":
    # "2026-07-29T20:22:19Z","terminal_state":"complete"}.
    assert_equals "and it is the null-based run_id, not a fabricated substitute" \
        "sha256:384d7e81ab298a2521b275327fa6dc00acc22fb959a364015e67ad20e7493dd2" \
        "$LEGACY_RUN_ID"

    # `legacy-version-gap` is the one reason here the Validator cannot
    # re-derive: it is a fact about the source Run's state file, echoed only
    # from the producer's compile_warnings. The exit code above does not depend
    # on it, because head-commit-unknown and reviewed-commit-unknown are
    # re-derived from `source` and force incomplete on their own, so the reason
    # has to be asserted against verify's own report.
    LEGACY_REASONS=$(verify_reasons "$LEGACY_BUNDLE")
    if [[ "$LEGACY_REASONS" == *legacy-version-gap* ]]; then
        pass "verify re-surfaces legacy-version-gap in its own report"
    else
        fail "verify legacy-version-gap" "legacy-version-gap" "$LEGACY_REASONS"
    fi
else
    fail "legacy export" "a bundle" "export failed"
fi

# And the mapping itself, on a Bundle whose only incomplete-forcing reason is
# the legacy gap. Dropping `legacy-version-gap` from the validator's incomplete
# set left every suite green, because the legacy fixture is always incomplete
# for two other reasons as well and no assertion could tell the difference.
ONLYGAP_RUN=$(make_run onlygap clean-complete)
ONLYGAP_BUNDLE=$(export_run "$ONLYGAP_RUN" onlygap)
if [[ -n "$ONLYGAP_BUNDLE" ]]; then
    rehash_bundle "$ONLYGAP_BUNDLE/proof.json" <<'PY'
bundle["integrity"]["compile_warnings"].append(
    {
        "reason": "legacy-version-gap",
        "target": "complete-state.md",
        "detail": "Injected: the only incomplete-forcing reason in this Bundle.",
    }
)
bundle["integrity"]["status"] = "incomplete"
PY
    assert_equals "legacy-version-gap on its own maps to incomplete with exit 2" \
        "2|incomplete" "$(verify_run "$ONLYGAP_BUNDLE")"
else
    fail "onlygap export" "a bundle" "export failed"
fi

# `legacy-version-gap` means "this Run predates the Recorder", which is why it
# requires all three Recorder facts to be absent. A modern Run where no review
# ran is missing only `reviewed_commit`, and calling that legacy would report a
# current Run as an old one. The distinction is asserted because the obvious
# widening -- warn when any Recorder fact is absent -- is wrong in exactly this
# case, and nothing else here would catch it. `ended_at` cannot be the odd one
# out: Loop writes it only alongside `head_commit`.
NOREVIEW_RUN=$(make_run noreview clean-complete)
python3 - "$NOREVIEW_RUN/complete-state.md" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(
    re.sub(r"^reviewed_commit:.*\n", "", text, count=1, flags=re.MULTILINE)
)
PY
NOREVIEW_BUNDLE=$(export_run "$NOREVIEW_RUN" noreview)
if [[ -n "$NOREVIEW_BUNDLE" ]]; then
    assert_equals "a Run that recorded no review is not reported as legacy" \
        "reviewed-commit-unknown" "$(warnings_of "$NOREVIEW_BUNDLE")"
    assert_equals "it is incomplete for the reason that is true of it" "2|incomplete" \
        "$(verify_run "$NOREVIEW_BUNDLE")"
else
    fail "noreview export" "a bundle" "export failed"
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

# A source that fits the cap must never be declared truncated. Masking
# substitutes a longer token than the path it replaces -- `/Users/q` is nine
# bytes and `<masked-home>` is thirteen -- so a review result at the cap masks
# to over it. Deciding truncation on the masked length wrote `status:
# truncated` with a `bytes` value that does not exceed the limit, the
# declaration contradicting the only fact that justifies it, while the
# identical source under local-v0 and the same cap was `included`.
MASKGROW_RUN=$(make_run maskgrow path-cited-review-complete)
python3 - "$MASKGROW_RUN/round-1-review-result.md" "$MAX_ITEM_BYTES" <<'PY'
import sys

path, cap = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read().rstrip(b"\n")
data += b"\n\nSee /Users/q for the workspace.\n"
# Exactly max_item_bytes: within the limit, so the source is not oversized.
data += b"." * (cap - len(data) - 1) + b"\n"
open(path, "wb").write(data)
PY

MASKGROW_BUNDLE=$(export_run "$MASKGROW_RUN" maskgrow public-v1)
if [[ -n "$MASKGROW_BUNDLE" ]]; then
    MASKGROW_ITEM=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
item = next(i for i in bundle['evidence'] if i['path'] == 'round-1-review-result.md')
print('%s|%s|%s' % (item['status'], item['omitted_reason'], item['bytes']))
" "$MASKGROW_BUNDLE")
    assert_equals "a source that fits the cap is withheld as omitted, not truncated" \
        "omitted|absolute-path|$MAX_ITEM_BYTES" "$MASKGROW_ITEM"

    # The general invariant, asserted over every item so a future size rule
    # cannot reintroduce the contradiction somewhere else in the Bundle.
    MASKGROW_CONTRADICTIONS=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
cap = int(sys.argv[2])
print(','.join(sorted(
    i['path'] for i in bundle['evidence']
    if i['status'] == 'truncated' and i['bytes'] <= cap
)))
" "$MASKGROW_BUNDLE" "$MAX_ITEM_BYTES")
    assert_equals "no truncated item declares a byte count within the limit" \
        "" "$MASKGROW_CONTRADICTIONS"

    # An omitted item is disclosed; the withheld-because-masking-grew case must
    # not be the one omission a reader cannot see.
    MASKGROW_DISCLOSED=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
print(','.join(sorted(
    e['reason'] for e in bundle['disclosure']['omitted']
    if e['path'] == 'round-1-review-result.md'
)))
" "$MASKGROW_BUNDLE")
    assert_equals "the withheld item is recorded in the disclosure" \
        "absolute-path" "$MASKGROW_DISCLOSED"

    assert_equals "and the Bundle is incomplete with exit 2, not valid" "2|incomplete" \
        "$(verify_run "$MASKGROW_BUNDLE")"
else
    fail "maskgrow export" "a bundle" "export failed"
fi

# The rule above withholds the item only because public-v1 can omit on the same
# scan class it masks. A profile that masks a class it cannot omit has no floor
# to fall to; every shipped profile satisfies that, and
# tests/proof_contract/test_contract.py holds all three of them to it.

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

    # Right kind, wrong review: pointing at the round-0 review that *raised*
    # the finding is not a re-review of it.
    EARLIER_BUNDLE="$TEST_DIR/bundles/link-earlier"
    cp -R "$LINK_BUNDLE" "$EARLIER_BUNDLE"
    rehash_bundle "$EARLIER_BUNDLE/proof.json" <<'PY'
raiser = next(
    item
    for item in bundle["evidence"]
    if item["path"] == "round-0-review-result.md" and item["status"] == "included"
)
for finding in bundle["findings"]:
    if "re_review_ref" in finding:
        finding["re_review_ref"] = raiser["id"]
PY
    assert_equals "a link to the review that raised the finding is invalid" "3|invalid" \
        "$(verify_run "$EARLIER_BUNDLE")"

    # A resolved finding with no recorded fix round cannot be checked at all.
    NO_FIX_ROUND_BUNDLE="$TEST_DIR/bundles/link-no-fix-round"
    cp -R "$LINK_BUNDLE" "$NO_FIX_ROUND_BUNDLE"
    rehash_bundle "$NO_FIX_ROUND_BUNDLE/proof.json" <<'PY'
for finding in bundle["findings"]:
    finding.pop("fix_round", None)
PY
    assert_equals "a resolved finding with no fix round is invalid" "3|invalid" \
        "$(verify_run "$NO_FIX_ROUND_BUNDLE")"

    # Naming the right review is not the same as that review saying the right
    # thing. Rewriting the linked review so it still carries the original
    # marker -- and re-hashing the evidence entry, its ID and the manifest so
    # nothing else is wrong -- must be rejected on the review's contents.
    REPEATED_BUNDLE="$TEST_DIR/bundles/link-repeated"
    cp -R "$LINK_BUNDLE" "$REPEATED_BUNDLE"
    # Byte-identical to the marker line the round-0 review raised: the finding
    # key is derived from the marker's summary, so a paraphrase would mint a
    # different identity and the assertion would pass without proving anything.
    rewrite_evidence "$REPEATED_BUNDLE" round-1-review-result.md \
        < "$REPEATED_BUNDLE/evidence/round-0-review-result.md"
    REPEATED_REASONS=$(verify_reasons "$REPEATED_BUNDLE")
    if [[ "$REPEATED_REASONS" != *hash-mismatch* && "$REPEATED_REASONS" != *proof-id-mismatch* ]]; then
        pass "the repeated-finding Bundle is coherent, so its contents are what is under test"
    else
        fail "repeated-finding rehash" "no hash or id mismatch" "$REPEATED_REASONS"
    fi
    assert_equals "a review that still records the finding is not a resolution" "3|invalid" \
        "$(verify_run "$REPEATED_BUNDLE")"

    # Spec section G resolves a finding against a later *parseable* review.
    # Checking only for the marker's absence accepted a review where nothing
    # could be read at all -- which is not the same as reading that the finding
    # is gone. The compiler calls these `unverifiable`; the validator must too.
    for review_case in "blank: " "malformed:- [Pbad] unparseable marker"; do
        review_label="${review_case%%:*}"
        review_body="${review_case#*:}"
        UNREADABLE_BUNDLE="$TEST_DIR/bundles/link-$review_label"
        cp -R "$LINK_BUNDLE" "$UNREADABLE_BUNDLE"
        printf '%s' "$review_body" |
            rewrite_evidence "$UNREADABLE_BUNDLE" round-1-review-result.md
        UNREADABLE_REASONS=$(verify_reasons "$UNREADABLE_BUNDLE")
        if [[ "$UNREADABLE_REASONS" != *hash-mismatch* && "$UNREADABLE_REASONS" != *proof-id-mismatch* ]]; then
            pass "the $review_label re-review Bundle is coherent, so its contents are what is under test"
        else
            fail "$review_label re-review rehash" "no hash or id mismatch" "$UNREADABLE_REASONS"
        fi
        assert_equals "a $review_label re-review cannot resolve a finding" "3|invalid" \
            "$(verify_run "$UNREADABLE_BUNDLE")"
    done

    # A waiver has to be backed by the record spec section G requires, not
    # merely by pointing at a Goal Tracker.
    FAKE_WAIVER_BUNDLE="$TEST_DIR/bundles/fake-waiver"
    cp -R "$LINK_BUNDLE" "$FAKE_WAIVER_BUNDLE"
    rehash_bundle "$FAKE_WAIVER_BUNDLE/proof.json" <<'PY'
tracker = next(
    item
    for item in bundle["evidence"]
    if item["path"] == "goal-tracker.md" and item["status"] == "included"
)
for finding in bundle["findings"]:
    finding["status"] = "waived"
    finding.pop("re_review_ref", None)
    finding.pop("fix_round", None)
    finding["waived_ref"] = tracker["id"]
PY
    assert_equals "a waiver with no Queued or Deferred record is invalid" "3|invalid" \
        "$(verify_run "$FAKE_WAIVER_BUNDLE")"
else
    fail "link export" "a bundle" "export failed"
fi

# A waiver that the Goal Tracker really does record must still verify, or the
# check above would just be rejecting every waiver.
GENUINE_WAIVER_RUN=$(make_run genuine-waiver clean-complete)
cat > "$GENUINE_WAIVER_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P3] Tidy the module docstring - greeting.py:1-1
  Cosmetic only.
REVIEW_EOF
python3 - "$GENUINE_WAIVER_RUN/goal-tracker.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    "| Issue | Discovered Round | Why Not Blocking | Revisit Trigger |\n"
    "|-------|-----------------|------------------|-----------------|",
    "| Issue | Discovered Round | Why Not Blocking | Revisit Trigger |\n"
    "|-------|-----------------|------------------|-----------------|\n"
    "| [P3] Tidy the module docstring | 0 | Cosmetic only | Next docs pass |",
)
open(path, "w", encoding="utf-8").write(text)
PY
GENUINE_WAIVER_BUNDLE=$(export_run "$GENUINE_WAIVER_RUN" genuine-waiver)
if [[ -n "$GENUINE_WAIVER_BUNDLE" ]]; then
    assert_equals "a recorded waiver verifies valid with exit 0" "0|valid" \
        "$(verify_run "$GENUINE_WAIVER_BUNDLE")"
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

    # The other half of "the Validator checks the declaration's self-
    # consistency" (spec section C): a truncated item must carry the size
    # reason. That guard is the only check the Validator applies to a truncated
    # declaration and nothing exercised it -- turning it off left all five
    # suites green -- so a refactor could drop it and let `truncated` be used
    # as an undisclosed omission that escapes the omission rules entirely.
    MISLABELLED_BUNDLE="$TEST_DIR/bundles/truncated-mislabelled"
    cp -R "$SILENT_SOURCE" "$MISLABELLED_BUNDLE"
    # `integrity.status` is deliberately left at the exported `incomplete`.
    # Declaring `invalid` here would make the exit code right for the wrong
    # reason -- integrity-status-mismatch -- and the assertion would hold with
    # the guard switched off.
    rehash_bundle "$MISLABELLED_BUNDLE/proof.json" <<'PY'
for item in bundle["evidence"]:
    if item["path"] == "round-0-prompt.md":
        item["omitted_reason"] = "profile-redaction"
PY
    assert_equals "a truncated item with the wrong omission reason is invalid at exit 3" \
        "3|invalid" "$(verify_run "$MISLABELLED_BUNDLE")"
    MISLABELLED_REASONS=$(verify_reasons "$MISLABELLED_BUNDLE")
    if [[ "$MISLABELLED_REASONS" == *profile-violation* ]]; then
        pass "and it is reported as a profile-violation"
    else
        fail "mislabelled truncation reason" "profile-violation" "$MISLABELLED_REASONS"
    fi

    # The other direction, and the one that mattered: the reason was right but
    # the size was not. `omitted` has its reason checked against the profile;
    # `truncated` did not, so any optional item could be withheld by calling it
    # truncated, deleting the bytes and re-hashing -- and the answer was
    # `incomplete`, which reads as a size problem rather than a withheld
    # artifact. `round-0-prompt.md` is 6032 bytes against a 1 MiB cap, and is
    # neither required by local-v0 nor referenced by an event, so nothing else
    # catches it.
    UNDERCAP_BUNDLE="$TEST_DIR/bundles/truncated-undercap"
    cp -R "$CLEAN_BUNDLE" "$UNDERCAP_BUNDLE"
    # The summary is derived from the real file before that file is removed, so
    # it is arithmetically sound and the size claim is the only thing wrong
    # here. Without it the item would also fail the summary rule, and this
    # assertion would hold with the size check switched off.
    export UNDERCAP_SUMMARY_JSON
    UNDERCAP_SUMMARY_JSON=$(python3 -c "
import json, sys
data = open(sys.argv[1], 'rb').read()
print(json.dumps({
    'algo': 'evidence-summary-v0',
    'lines': data.count(b'\n') + (1 if data and not data.endswith(b'\n') else 0),
    'longest_line_bytes': max((len(part) for part in data.split(b'\n')), default=0),
}))
" "$UNDERCAP_BUNDLE/evidence/round-0-prompt.md")
    rm "$UNDERCAP_BUNDLE/evidence/round-0-prompt.md"
    rehash_bundle "$UNDERCAP_BUNDLE/proof.json" <<'PY'
import json
import os

for item in bundle["evidence"]:
    if item["path"] == "round-0-prompt.md":
        assert item["bytes"] <= 1048576, item["bytes"]
        item["status"] = "truncated"
        item["omitted_reason"] = "size-limit"
        item["summary"] = json.loads(os.environ["UNDERCAP_SUMMARY_JSON"])
bundle["integrity"]["status"] = "incomplete"
PY
    assert_equals "a truncated item that fits the cap is invalid at exit 3" \
        "3|invalid" "$(verify_run "$UNDERCAP_BUNDLE")"
    UNDERCAP_REASONS=$(verify_reasons "$UNDERCAP_BUNDLE")
    if [[ "$UNDERCAP_REASONS" == *profile-violation* ]]; then
        pass "and withholding it as truncated is a profile-violation"
    else
        fail "under-cap truncation reason" "profile-violation" "$UNDERCAP_REASONS"
    fi

    # A truncated declaration says the item was too large to carry, so carrying
    # it anyway contradicts the declaration -- and hands the recipient the very
    # bytes the Bundle says it withheld, inside a bundle budget computed without
    # them. `omitted` has had this rule from the start; `truncated` had no
    # presence check at all, so putting the source back under evidence/ verified
    # as merely incomplete.
    RETAINED_BUNDLE="$TEST_DIR/bundles/truncated-retained"
    cp -R "$SILENT_SOURCE" "$RETAINED_BUNDLE"
    cp "$SILENT_RUN/round-0-prompt.md" "$RETAINED_BUNDLE/evidence/round-0-prompt.md"
    assert_equals "a truncated item whose bytes are in the Bundle is invalid at exit 3" \
        "3|invalid" "$(verify_run "$RETAINED_BUNDLE")"
    RETAINED_REASONS=$(verify_reasons "$RETAINED_BUNDLE")
    if [[ "$RETAINED_REASONS" == *profile-violation* ]]; then
        pass "and distributing the withheld bytes is a profile-violation"
    else
        fail "retained truncation reason" "profile-violation" "$RETAINED_REASONS"
    fi

    # Spec section C's third clause: "a summary plus the original sha256 and
    # original byte count". The summary carries no content -- truncation is a
    # disclosure boundary in this codebase, and the Compiler already strips the
    # goal, the criteria, the state frontmatter and review prose across it, so
    # a summary quoting the withheld bytes would hand back exactly what those
    # sites remove (ADR-0008). What it carries instead is shape, and every
    # member is checkable against the item's own byte count.
    SUMMARY_ITEM=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
item = next(i for i in bundle['evidence'] if i['path'] == 'round-0-prompt.md')
summary = item.get('summary')
print(json.dumps(summary, sort_keys=True) if summary is not None else 'absent')
" "$SILENT_SOURCE")
    assert_equals "a truncated item carries a content-free shape summary" \
        '{"algo": "evidence-summary-v0", "lines": 2, "longest_line_bytes": 1200000}' \
        "$SUMMARY_ITEM"

    # Only a withheld-for-size item has anything to summarize, and the summary
    # is a bounded disclosure surface: it must not appear on items the Bundle
    # already publishes in full.
    SUMMARY_ELSEWHERE=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
print(','.join(sorted(
    i['path'] for i in bundle['evidence']
    if i['status'] != 'truncated' and 'summary' in i
)))
" "$SILENT_SOURCE")
    assert_equals "no published item carries a summary" "" "$SUMMARY_ELSEWHERE"

    # Each rule below is checked on a Bundle whose only defect is that rule, so
    # a green result cannot come from a neighbouring check.
    for broken in \
        "missing:del item['summary']" \
        "extra-member:item['summary']['excerpt'] = 'BEGIN RSA PRIVATE KEY'" \
        "wrong-algo:item['summary']['algo'] = 'evidence-summary-v9'" \
        "impossible-lines:item['summary']['lines'] = item['bytes'] + 1" \
        "impossible-length:item['summary']['longest_line_bytes'] = item['bytes'] + 1" \
        "shape-does-not-fit:item['summary'].update({'lines': 3, 'longest_line_bytes': item['bytes'] - 1})" \
        "no-lines:item['summary']['lines'] = 0" \
        ; do
        BROKEN_LABEL="${broken%%:*}"
        BROKEN_CODE="${broken#*:}"
        BROKEN_BUNDLE="$TEST_DIR/bundles/summary-$BROKEN_LABEL"
        cp -R "$SILENT_SOURCE" "$BROKEN_BUNDLE"
        export BROKEN_SUMMARY_CODE="$BROKEN_CODE"
        # `integrity.status` stays at the exported `incomplete`. Declaring
        # `invalid` would make the exit code right for the wrong reason --
        # integrity-status-mismatch -- and every case below would hold with the
        # summary rule switched off.
        rehash_bundle "$BROKEN_BUNDLE/proof.json" <<'PY'
import os

for item in bundle["evidence"]:
    if item["path"] == "round-0-prompt.md":
        exec(os.environ["BROKEN_SUMMARY_CODE"], {"item": item})
PY
        assert_equals "a $BROKEN_LABEL summary is invalid at exit 3" \
            "3|invalid" "$(verify_run "$BROKEN_BUNDLE")"
    done
else
    fail "silent truncation export" "a bundle" "export failed"
fi

echo ""
echo "Section 7: Round coverage is derived by the verifier, not read off the producer"

# The compiler records a coverage gap as a warning. If the validator only
# replayed those warnings, deleting one and re-hashing would make the gap
# disappear -- the producer's account of itself would be the only thing checked.
COVERAGE_RUN=$(make_run coverage clean-complete)
cp "$COVERAGE_RUN/round-0-summary.md" "$COVERAGE_RUN/round-2-summary.md"
cp "$COVERAGE_RUN/round-0-review-result.md" "$COVERAGE_RUN/round-2-review-result.md"
cp "$COVERAGE_RUN/round-0-contract.md" "$COVERAGE_RUN/round-1-contract.md"

COVERAGE_BUNDLE=$(export_run "$COVERAGE_RUN" coverage)
if [[ -n "$COVERAGE_BUNDLE" ]]; then
    assert_equals "a round with no summary or review is incomplete with exit 2" \
        "2|incomplete" "$(verify_run "$COVERAGE_BUNDLE")"

    SILENCED_COVERAGE="$TEST_DIR/bundles/coverage-silenced"
    cp -R "$COVERAGE_BUNDLE" "$SILENCED_COVERAGE"
    rehash_bundle "$SILENCED_COVERAGE/proof.json" <<'PY'
integrity = bundle["integrity"]
integrity["compile_warnings"] = [
    warning
    for warning in integrity["compile_warnings"]
    if warning.get("target") != "round-1"
]
integrity["status"] = "valid"
bundle["verdict"]["decision"] = "accept"
PY
    SILENCED_REASONS=$(verify_reasons "$SILENCED_COVERAGE")
    if [[ "$SILENCED_REASONS" != *proof-id-mismatch* ]]; then
        pass "the silenced coverage Bundle re-hashed cleanly, so the rule is what is under test"
    else
        fail "silenced coverage rehash" "no proof-id-mismatch" "$SILENCED_REASONS"
    fi
    if [[ "$SILENCED_REASONS" == *profile-required-evidence-missing* ]]; then
        pass "the verifier derives the coverage gap without the compiler's warning"
    else
        fail "independent coverage check" "profile-required-evidence-missing" "$SILENCED_REASONS"
    fi
    assert_equals "and declaring it valid is caught as a status mismatch" "3|invalid" \
        "$(verify_run "$SILENCED_COVERAGE")"
else
    fail "coverage export" "a bundle" "export failed"
fi

echo ""
echo "Section 8: A reviewed commit behind head withholds the badge (D8)"

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
echo "=== Scenario: masked publication (ADR-0004) ==="

# `public-v1` publishes a path-citing review result masked rather than
# withholding it. The masked copy is the file a recipient receives, so it is
# the one tamper detection has to bite on. (`public-v0` is frozen per
# ADR-0006 and never masks.)
MASK_RUN=$(make_run mask-tamper path-cited-review-complete)
MASK_BUNDLE=$(export_run "$MASK_RUN" mask-tamper public-v1)
if [[ -n "$MASK_BUNDLE" ]]; then
    assert_equals "a masked Bundle verifies valid at exit 0" "0|valid" \
        "$(verify_run "$MASK_BUNDLE")"

    # No re-hash is needed: `sha256` still names the source, so the Evidence ID
    # and proof_id stay coherent and the Bundle fails on the check under test
    # rather than on proof-id-mismatch.
    TAMPERED_MASK="$TEST_DIR/bundles/mask-tampered"
    rm -rf "$TAMPERED_MASK"
    cp -R "$MASK_BUNDLE" "$TAMPERED_MASK"
    printf 'appended after masking\n' \
        >> "$TAMPERED_MASK/evidence/round-1-review-result.md"
    assert_equals "editing the masked copy is invalid at exit 3" "3|invalid" \
        "$(verify_run "$TAMPERED_MASK")"
    MASK_TAMPER_REASONS=$(verify_reasons "$TAMPERED_MASK")
    if [[ "$MASK_TAMPER_REASONS" == *"hash-mismatch"* ]]; then
        pass "and it is reported as hash-mismatch ($MASK_TAMPER_REASONS)"
    else
        fail "masked tamper reason" "hash-mismatch" "$MASK_TAMPER_REASONS"
    fi

    # A profile with no masking rule never granted the licence, so a Bundle
    # that claims one is describing a profile it did not use.
    #
    # Built from the local-v0 Bundle rather than by relabelling the public
    # one's profile: local-v0 omits nothing, so the only rule this Bundle can
    # break is the masking licence. Repointing the public Bundle at local-v0
    # instead made every profile-redacted prompt illegitimate too, and the
    # assertion passed on those whether the licence check ran or not.
    UNLICENSED_MASK="$TEST_DIR/bundles/mask-unlicensed"
    rm -rf "$UNLICENSED_MASK"
    cp -R "$(export_run "$MASK_RUN" mask-unlicensed-src local-v0)" "$UNLICENSED_MASK"
    cp "$MASK_BUNDLE/evidence/round-1-review-result.md" \
        "$UNLICENSED_MASK/evidence/round-1-review-result.md"
    rehash_bundle "$UNLICENSED_MASK/proof.json" <<'PY'
import hashlib
import os

data = open(
    os.path.join(os.path.dirname(path), "evidence", "round-1-review-result.md"), "rb"
).read()
for item in bundle["evidence"]:
    if item["path"] == "round-1-review-result.md":
        # `sha256` and `bytes` keep naming the source, as a real masked item's
        # would; only the published pair describes the masked copy.
        item["status"] = "masked"
        item["masked_sha256"] = hashlib.sha256(data).hexdigest()
        item["masked_bytes"] = len(data)
PY
    UNLICENSED_REASONS=$(verify_reasons "$UNLICENSED_MASK")
    if [[ "$UNLICENSED_REASONS" == *"profile-violation"* ]]; then
        pass "masking under a profile that allows none is a profile-violation"
    else
        fail "unlicensed mask" "profile-violation" "$UNLICENSED_REASONS"
    fi

    # Masking that left a path behind publishes the very thing the rule exists
    # to catch, so declaring the item masked must not launder it through.
    #
    # Only the published pair is updated here. `rewrite_evidence` would also
    # rewrite `sha256`, which would make it equal `masked_sha256` and trip the
    # "masked evidence must differ from its source" rule instead -- the
    # assertion then passed whether or not the path check ran.
    DIRTY_MASK="$TEST_DIR/bundles/mask-dirty"
    rm -rf "$DIRTY_MASK"
    cp -R "$MASK_BUNDLE" "$DIRTY_MASK"
    printf -- '- [P1] Still cites /Users/example/project/csv_writer.py:1-1\n' \
        > "$DIRTY_MASK/evidence/round-1-review-result.md"
    rehash_bundle "$DIRTY_MASK/proof.json" <<'PY'
import hashlib
import os

data = open(
    os.path.join(os.path.dirname(path), "evidence", "round-1-review-result.md"), "rb"
).read()
for item in bundle["evidence"]:
    if item["path"] == "round-1-review-result.md":
        item["masked_sha256"] = hashlib.sha256(data).hexdigest()
        item["masked_bytes"] = len(data)
PY
    DIRTY_REASONS=$(verify_reasons "$DIRTY_MASK")
    if [[ "$DIRTY_REASONS" == *"profile-violation"* ]]; then
        pass "a masked item that still carries a home path is a profile-violation"
    else
        fail "dirty mask" "profile-violation" "$DIRTY_REASONS"
    fi

    # The masked declaration is reconciled like the omitted one: a Bundle
    # whose declaration is missing, padded, or duplicated is describing a
    # disclosure that did not happen, and a declaration a producer can
    # silently drop is not a declaration.
    NO_DECL_MASK="$TEST_DIR/bundles/mask-no-declaration"
    rm -rf "$NO_DECL_MASK"
    cp -R "$MASK_BUNDLE" "$NO_DECL_MASK"
    rehash_bundle "$NO_DECL_MASK/proof.json" <<'PY'
bundle["disclosure"].pop("masked", None)
PY
    NO_DECL_REASONS=$(verify_reasons "$NO_DECL_MASK")
    if [[ "$NO_DECL_REASONS" == *"profile-violation"* ]]; then
        pass "dropping disclosure.masked from a masked Bundle is a profile-violation"
    else
        fail "missing masked declaration" "profile-violation" "$NO_DECL_REASONS"
    fi

    DUP_DECL_MASK="$TEST_DIR/bundles/mask-duplicate-declaration"
    rm -rf "$DUP_DECL_MASK"
    cp -R "$MASK_BUNDLE" "$DUP_DECL_MASK"
    rehash_bundle "$DUP_DECL_MASK/proof.json" <<'PY'
declared = bundle["disclosure"]["masked"]
declared.append(dict(declared[0]))
PY
    DUP_DECL_REASONS=$(verify_reasons "$DUP_DECL_MASK")
    if [[ "$DUP_DECL_REASONS" == *"profile-violation"* ]]; then
        pass "a duplicated masked declaration is a profile-violation"
    else
        fail "duplicate masked declaration" "profile-violation" "$DUP_DECL_REASONS"
    fi

    FAKE_DECL_MASK="$TEST_DIR/bundles/mask-fabricated-declaration"
    rm -rf "$FAKE_DECL_MASK"
    cp -R "$MASK_BUNDLE" "$FAKE_DECL_MASK"
    rehash_bundle "$FAKE_DECL_MASK/proof.json" <<'PY'
bundle["disclosure"]["masked"].append(
    {"path": "round-0-summary.md", "rule": "absolute-path"}
)
PY
    FAKE_DECL_REASONS=$(verify_reasons "$FAKE_DECL_MASK")
    if [[ "$FAKE_DECL_REASONS" == *"profile-violation"* ]]; then
        pass "declaring an item masked that is not is a profile-violation"
    else
        fail "fabricated masked declaration" "profile-violation" "$FAKE_DECL_REASONS"
    fi
else
    fail "masked export" "a bundle" "export failed"
fi

# A freshly exported Bundle that masks nothing carries no masked item and no
# declaration, and verifies valid.
PREMASK_RUN=$(make_run pre-mask clean-complete)
PREMASK_BUNDLE=$(export_run "$PREMASK_RUN" pre-mask public-v1)
if [[ -n "$PREMASK_BUNDLE" ]]; then
    assert_equals "a v1 Bundle with no masked evidence verifies valid" "0|valid" \
        "$(verify_run "$PREMASK_BUNDLE")"
else
    fail "pre-mask export" "a bundle" "export failed"
fi

# The real backward-compatibility check: a byte-for-byte archived Bundle,
# exported by the pre-masking exporter under the then-current `public-v0`,
# must verify valid with today's CLI. Re-exporting with today's code cannot
# test this -- it pins today's profile hash -- which is how the in-place
# `public-v0` revision shipped with this claim green while every archived
# public Bundle failed on `profile.schema_hash` (ADR-0006).
BASELINE_BUNDLE="$PROJECT_ROOT/tests/fixtures/proof/bundles/pre-masking-public-v0"
assert_equals "an archived pre-masking public-v0 Bundle verifies valid unchanged" \
    "0|valid" "$(verify_run "$BASELINE_BUNDLE")"

# ========================================
# Files the compiler does not recognise
# ========================================

echo ""
echo "Section 9: An unrecognized file is kept, named, and costs the badge"

# spec section F: an unrecognized file is recorded as `kind: unknown` and
# produces a warning. The warning reuses `unparseable-artifact`, which section
# J maps to `incomplete`, so a stray file costs the Bundle its badge. That is
# the contract; it is asserted as a pair because deleting the warning alone
# left every suite green while flipping verify from exit 2 to exit 0.
STRAY_RUN=$(make_run stray clean-complete)
printf 'scratch notes\n' > "$STRAY_RUN/scratch-notes.txt"
STRAY_BUNDLE=$(export_run "$STRAY_RUN" stray)
if [[ -n "$STRAY_BUNDLE" ]]; then
    assert_equals "an unrecognized file is kept as kind unknown and named in a warning" \
        "unknown/included|incomplete|unparseable-artifact" \
        "$(item_report_of "$STRAY_BUNDLE" scratch-notes.txt)"

    # "Never discarded" means the bytes are really there and really hash to
    # what the manifest declares -- not merely that a row exists.
    STRAY_BYTES=$(python3 -c "
import hashlib, json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
item = next(i for i in bundle['evidence'] if i['path'] == 'scratch-notes.txt')
data = open(sys.argv[1] + '/evidence/scratch-notes.txt', 'rb').read()
print('%s|%s' % (
    hashlib.sha256(data).hexdigest() == item['sha256'],
    len(data) == item['bytes'],
))
" "$STRAY_BUNDLE")
    assert_equals "its bytes are in the Bundle and match the declaration" \
        "True|True" "$STRAY_BYTES"

    assert_equals "the stray file makes the Bundle incomplete at exit 2" "2|incomplete" \
        "$(verify_run "$STRAY_BUNDLE")"

    # The compile-warning replay is the only path by which
    # `unparseable-artifact` reaches verify at all, and nothing exercised it:
    # the whole replay loop could be deleted with all five suites green.
    STRAY_REASONS=$(verify_reasons "$STRAY_BUNDLE")
    if [[ "$STRAY_REASONS" == *unparseable-artifact* ]]; then
        pass "verify re-surfaces unparseable-artifact in its own report"
    else
        fail "verify unparseable-artifact" "unparseable-artifact" "$STRAY_REASONS"
    fi
else
    fail "stray export" "a bundle" "export failed"
fi

# A Loop-authored control marker is recognized metadata, not an unrecognized
# artifact: it is kept as evidence and costs nothing. `.cancel-requested` and
# `.review-phase-started` were already recognized. `.methodology-exit-reason`
# is written by hooks/lib/methodology-analysis.sh and is the third of the same
# family; it was classified as a stray file.
MARKER_RUN=$(make_run marker clean-complete)
printf 'complete\n' > "$MARKER_RUN/.methodology-exit-reason"
MARKER_BUNDLE=$(export_run "$MARKER_RUN" marker)
if [[ -n "$MARKER_BUNDLE" ]]; then
    assert_equals "a Loop control marker is kept as evidence with no warning" \
        "unknown/included|valid|" \
        "$(item_report_of "$MARKER_BUNDLE" .methodology-exit-reason)"
    assert_equals "and the marker does not cost the Bundle its badge" "0|valid" \
        "$(verify_run "$MARKER_BUNDLE")"
else
    fail "marker export" "a bundle" "export failed"
fi

# `.DS_Store` is macOS noise rather than a Run artifact, and is skipped. The
# skip matched the exact relative path, so only the Run root was skipped while
# `sub/.DS_Store` was retained as kind unknown and cost the Bundle its badge --
# the same bytes treated in opposite ways. The skip now matches the file name
# at any depth, and spec section F names the exception instead of claiming it
# never happens.
NOISE_RUN=$(make_run noise clean-complete)
printf 'macos noise\n' > "$NOISE_RUN/.DS_Store"
mkdir -p "$NOISE_RUN/sub"
printf 'macos noise\n' > "$NOISE_RUN/sub/.DS_Store"
NOISE_BUNDLE=$(export_run "$NOISE_RUN" noise)
if [[ -n "$NOISE_BUNDLE" ]]; then
    NOISE_PATHS=$(python3 -c "
import json, sys
bundle = json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))
print(','.join(sorted(
    i['path'] for i in bundle['evidence'] if i['path'].endswith('.DS_Store')
)))
" "$NOISE_BUNDLE")
    assert_equals "no .DS_Store is collected, at the root or below it" "" "$NOISE_PATHS"
    assert_equals "and OS noise does not cost the Bundle its badge" "0|valid" \
        "$(verify_run "$NOISE_BUNDLE")"
else
    fail "noise export" "a bundle" "export failed"
fi

# ========================================
# Source artifacts the compiler cannot read
# ========================================

echo ""
echo "Section 10: An unreadable source artifact names itself and costs a conclusion"

# AC-10: a missing file and an unparseable review result each produce a
# specific warning rather than a crash or a silent pass. The behaviour was
# right and none of it was asserted. No fixture could reach the adapter's
# missing-file branch -- tests/proof_contract/test_run_fixtures.py positively
# requires plan.md and goal-tracker.md in every Run fixture -- so replacing
# both warnings with `pass` left all five suites green.
# A missing goal-tracker.md is warned about twice, and both are wanted: it is
# missing, and the tables the verdict reads cannot be parsed from a file that
# is not there. The pair is asserted exactly so neither can quietly disappear.
for missing in "plan.md:missing-file:stated scope" \
               "goal-tracker.md:missing-file,unparseable-artifact:no acceptance criterion can be assessed"; do
    MISSING_FILE="${missing%%:*}"
    MISSING_REST="${missing#*:}"
    MISSING_REASONS="${MISSING_REST%%:*}"
    MISSING_CONCLUSION="${MISSING_REST#*:}"
    MISSING_LABEL="missing-${MISSING_FILE%.md}"
    MISSING_RUN=$(make_run "$MISSING_LABEL" clean-complete)
    rm "$MISSING_RUN/$MISSING_FILE"
    MISSING_BUNDLE=$(export_run "$MISSING_RUN" "$MISSING_LABEL")
    if [[ -n "$MISSING_BUNDLE" ]]; then
        pass "a Run with no $MISSING_FILE still exports rather than crashing"
        # `absent` because the file cannot be collected: the warning is the
        # only record that it was expected at all.
        assert_equals "the warning names $MISSING_FILE and the Bundle is incomplete" \
            "absent|incomplete|$MISSING_REASONS" \
            "$(item_report_of "$MISSING_BUNDLE" "$MISSING_FILE")"
        # AC-10 wants the conclusion too, not just the file: a reader should
        # not have to infer what became unassessable from the final status.
        MISSING_DETAIL=$(warning_detail_of "$MISSING_BUNDLE" "$MISSING_FILE")
        if [[ "$MISSING_DETAIL" == *"$MISSING_CONCLUSION"* ]]; then
            pass "and it names the conclusion losing $MISSING_FILE costs"
        else
            fail "$MISSING_FILE conclusion" "a detail naming '$MISSING_CONCLUSION'" "$MISSING_DETAIL"
        fi
        assert_equals "a Run with no $MISSING_FILE verifies incomplete with exit 2" \
            "2|incomplete" "$(verify_run "$MISSING_BUNDLE")"
    else
        fail "$MISSING_LABEL export" "a bundle" "export failed"
    fi
done

# An empty review result and one that is not UTF-8 both reach the same
# published-but-unreadable branch. Deleting that warning flipped an
# empty-review export from `incomplete` to `valid` with no warnings at all,
# and all five suites stayed green. The non-UTF-8 half was unexercised
# entirely.
#
# Defined here rather than in the shared helper block at the top of the file:
# this runs a whole scenario for one input shape and is local to this section,
# where the helpers above are utilities every section uses.
unreadable_review_case() {
    local label="$1"
    local description="$2"
    local run_dir
    run_dir=$(make_run "$label" clean-complete)
    python3 - "$run_dir/round-0-review-result.md" "$label" <<'PY'
import sys

path, label = sys.argv[1], sys.argv[2]
# An empty file and undecodable bytes are different inputs that must not be
# told apart by the conclusion they support: neither can establish a finding.
open(path, "wb").write(b"" if label == "empty-review" else b"\xff\xfe\x00binary junk\n")
PY
    local bundle
    bundle=$(export_run "$run_dir" "$label")
    if [[ -n "$bundle" ]]; then
        pass "$description still exports rather than crashing"
        assert_equals "$description warns unparseable-artifact naming the review" \
            "round_review_result/included|incomplete|unparseable-artifact" \
            "$(item_report_of "$bundle" round-0-review-result.md)"
        # The conclusion it costs: with no readable review the delivery cannot
        # be assessed, and saying so is the point of the warning.
        assert_equals "$description leaves the decision unverifiable" "unverifiable" \
            "$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1] + '/proof.json', encoding='utf-8'))['verdict']['decision'])
" "$bundle")"
        assert_equals "$description verifies incomplete with exit 2" "2|incomplete" \
            "$(verify_run "$bundle")"
    else
        fail "$label export" "a bundle" "export failed"
    fi
}

unreadable_review_case empty-review "an empty review result"
unreadable_review_case binary-review "a review result that is not UTF-8"

# ========================================
# The CLI exit-code contract (spec section J)
# ========================================

echo ""
echo "Section 11: The exit codes the CLI reserves for its callers"

# Section J keeps exit 1 distinct from the integrity codes so CI can tell "this
# Bundle is bad" from "you called me wrong". Nothing asserted it for verify:
# every call site in the suites passes a well-formed Bundle path. Deleting the
# `_ArgumentParser` subclass in scripts/proof-verify.py silently moved usage
# errors from 1 to 2 -- the code section J reserves for `incomplete` -- with
# all five suites green.
assert_equals "verify with no arguments is a usage error, not a verdict" "1" \
    "$(proof_exit verify)"
assert_equals "verify with an unrecognized flag is a usage error" "1" \
    "$(proof_exit verify --no-such-flag "$CLEAN_BUNDLE")"

# A path that is not a Bundle reports `invalid` rather than a usage error,
# because proof.json cannot be parsed from it. That reads oddly against section
# J's "usage/environment error" -- nothing was forged, there is simply no
# Bundle there -- but it is the shipped behaviour and changing it is a separate
# decision. Pinned so that change has to be a deliberate one.
assert_equals "a path with no Bundle in it reports invalid, not usage" "3" \
    "$(proof_exit verify "$TEST_DIR/no-such-bundle")"

# Export exit 4 is the one code in section J's export contract with no
# assertion anywhere: deleting the whole `except RunUnreadableError` clause
# collapsed it to 1 without a red test. The three shapes below are distinct
# paths to it -- the directory is absent, the path is not a directory, and the
# state file cannot be read as a Run.
UNREADABLE_DIR="$TEST_DIR/unreadable"
mkdir -p "$UNREADABLE_DIR"
printf 'not a run\n' > "$UNREADABLE_DIR/plain-file"
mkdir -p "$UNREADABLE_DIR/no-frontmatter"
printf 'no frontmatter at all\n' > "$UNREADABLE_DIR/no-frontmatter/complete-state.md"

assert_equals "exporting a Run directory that is not there is exit 4" "4" \
    "$(proof_exit export --run "$UNREADABLE_DIR/absent" --out "$TEST_DIR/bundles/unreadable-1")"
assert_equals "exporting a path that is not a directory is exit 4" "4" \
    "$(proof_exit export --run "$UNREADABLE_DIR/plain-file" --out "$TEST_DIR/bundles/unreadable-2")"
assert_equals "exporting a state file with no frontmatter is exit 4" "4" \
    "$(proof_exit export --run "$UNREADABLE_DIR/no-frontmatter" --out "$TEST_DIR/bundles/unreadable-3")"

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
