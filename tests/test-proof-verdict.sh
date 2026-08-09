#!/usr/bin/env bash
# Verdict Deriver coverage: per-AC status, finding lifecycle, overall decision.
#
# The rule these all serve is ADR-0002: derive from structured facts only --
# Goal Tracker section moves, [P0-9] markers, Terminal State -- and mark
# anything unparseable `unverifiable` rather than guessing. Zero evidence must
# never produce `met`, and `reject` is never derived at all.
#
# Each scenario copies a golden Run and mutates one thing, so the assertion
# names the single fact under test. `clean-complete` is the control: it derives
# `accept` with all five criteria `met`, so any scenario that stops being green
# stopped for the reason the scenario introduced.

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
    echo "Proof verdict tests require Python 3.9 or newer." >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

echo "========================================"
echo "Proof Verdict Tests"
echo "========================================"

# Build an isolated project holding one Run copied from a golden fixture.
# Every scenario gets its own project so a mutation cannot leak sideways.
# Usage: make_run <scenario-name> [fixture]
make_run() {
    local name="$1"
    local fixture="${2:-clean-complete}"
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

# Export a Run and print the bundle path, or print nothing on failure.
# Usage: export_run <run-dir> <out-name> [profile]
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

# Read one derived value out of a Bundle. The queries stay in Python so the
# assertions compare exact values rather than grepping formatted output.
# Usage: probe <bundle> <query>
probe() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1] + "/proof.json", encoding="utf-8"))
query = sys.argv[2]
verdict = bundle.get("verdict", {})
findings = bundle.get("findings", [])


def ac(ac_id):
    for item in verdict.get("per_ac", []):
        if item["ac_id"] == ac_id:
            return item
    return {}


if query == "decision":
    print(verdict.get("decision", ""))
elif query == "statuses":
    print(",".join(sorted({item["status"] for item in verdict.get("per_ac", [])})))
elif query == "required_set":
    print(",".join(verdict.get("required_set", [])))
elif query == "finding_statuses":
    print(",".join(item["status"] for item in findings))
elif query == "finding_count":
    print(len(findings))
elif query.startswith("ac:"):
    print(ac(query[3:]).get("status", "absent"))
elif query.startswith("evidence_status:"):
    wanted = query[len("evidence_status:") :]
    print(
        next(
            (
                item["status"]
                for item in bundle.get("evidence", [])
                if item.get("path") == wanted
            ),
            "absent",
        )
    )
elif query.startswith("evidence_sha256:"):
    wanted = query[len("evidence_sha256:") :]
    print(
        next(
            (
                item["sha256"]
                for item in bundle.get("evidence", [])
                if item.get("path") == wanted
            ),
            "absent",
        )
    )
elif query.startswith("ac_text:"):
    wanted = query[len("ac_text:") :]
    criteria = bundle.get("specification", {}).get("acceptance_criteria", [])
    print(
        next(
            (item["text"] for item in criteria if item["id"] == wanted),
            "absent",
        )
    )
elif query.startswith("ac_contradicting:"):
    print(len(ac(query[17:]).get("contradicting", [])))
elif query.startswith("finding_field:"):
    field = query[len("finding_field:") :]
    print(",".join(str(item.get(field, "absent")) for item in findings))
elif query == "deferred_ac_ids":
    print(",".join(item["ac_id"] for item in verdict.get("deferred", [])))
elif query == "warning_reasons":
    print(
        ",".join(
            sorted({w["reason"] for w in bundle["integrity"]["compile_warnings"]})
        )
    )
elif query == "integrity":
    print(bundle["integrity"]["status"])
elif query == "deferred_has_replan_ref":
    entries = verdict.get("deferred", [])
    print(
        "yes"
        if entries and all(item.get("replan_ref") for item in entries)
        else "no"
    )
else:
    raise SystemExit("unknown query " + query)
PY
}

# Report whether a written evidence file still carries an absolute home path.
# Scanned here rather than read off the manifest, so the assertion checks the
# bytes a recipient receives rather than the exporter's account of them.
# Usage: scan_home_paths <file>
scan_home_paths() {
    python3 - "$1" <<'PY'
import re
import sys

pattern = re.compile(r"(?<![A-Za-z0-9._-])/(?:Users|home)/[^\s/]+")
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
print("dirty" if pattern.search(text) else "clean")
PY
}

# Report which declared hash the written file actually matches.
# Usage: hash_matches <bundle> <evidence-relative-path>
hash_matches() {
    python3 - "$1" "$2" <<'PY'
import hashlib
import json
import sys

bundle, relative = sys.argv[1], sys.argv[2]
manifest = json.load(open(bundle + "/proof.json", encoding="utf-8"))
item = next(
    (entry for entry in manifest["evidence"] if entry.get("path") == relative), None
)
if item is None:
    print("absent")
    raise SystemExit(0)
digest = hashlib.sha256(open(bundle + "/evidence/" + relative, "rb").read()).hexdigest()
if digest == item.get("masked_sha256"):
    print("masked")
elif digest == item.get("sha256"):
    print("source")
else:
    print("neither")
PY
}

# Replace a whole "| ... |" table body under a heading, keeping the header rows.
# Usage: append_table_row <goal-tracker> <heading> <row>
append_table_row() {
    python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

path, heading, row = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
out = []
inside = False
inserted = False
for index, line in enumerate(lines):
    if re.match(r"^#+\s*" + re.escape(heading) + r"\s*$", line):
        inside = True
        out.append(line)
        continue
    if inside and not inserted:
        # Insert after the header and separator rows of this section's table.
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if line.startswith("|") and not following.startswith("|"):
            out.append(line)
            out.append(row)
            inserted = True
            inside = False
            continue
    out.append(line)
if not inserted:
    raise SystemExit("could not find a table under heading " + heading)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

# ========================================
# Control
# ========================================

echo ""
echo "Section 1: Control -- a clean complete Run"

CONTROL_RUN=$(make_run control)
CONTROL_BUNDLE=$(export_run "$CONTROL_RUN" control)
if [[ -n "$CONTROL_BUNDLE" ]]; then
    assert_equals "clean complete Run derives accept" "accept" "$(probe "$CONTROL_BUNDLE" decision)"
    assert_equals "every criterion is met" "met" "$(probe "$CONTROL_BUNDLE" statuses)"
    assert_equals "no findings are recorded" "0" "$(probe "$CONTROL_BUNDLE" finding_count)"
else
    fail "control export" "a bundle" "export failed"
fi

# ========================================
# Zero evidence never yields met (AC-4)
# ========================================

echo ""
echo "Section 2: Placeholder acceptance criteria"

PLACEHOLDER_RUN=$(make_run placeholder)
python3 - "$PLACEHOLDER_RUN/goal-tracker.md" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# Keep the criteria section present but purely placeholder, and empty the
# Completed and Verified table so nothing structured remains to read.
text = re.sub(
    r"(### Acceptance Criteria\n)(.*?)(\n---)",
    r"\1<!-- placeholder -->\n\n[To be defined in Round 0]\n\3",
    text,
    flags=re.DOTALL,
)
text = re.sub(
    r"(\| AC \| Task \| Completed Round \| Verified Round \| Evidence \|\n\|[-| ]+\|\n)(?:\|.*\n)*",
    r"\1",
    text,
)
open(path, "w", encoding="utf-8").write(text)
PY

PLACEHOLDER_BUNDLE=$(export_run "$PLACEHOLDER_RUN" placeholder)
if [[ -n "$PLACEHOLDER_BUNDLE" ]]; then
    PLACEHOLDER_STATUSES=$(probe "$PLACEHOLDER_BUNDLE" statuses)
    if [[ "$PLACEHOLDER_STATUSES" != *met* ]]; then
        pass "placeholder criteria never derive met (statuses: ${PLACEHOLDER_STATUSES:-none})"
    else
        fail "placeholder criteria" "no met status" "$PLACEHOLDER_STATUSES"
    fi
    assert_equals "placeholder criteria do not derive accept" "unverifiable" \
        "$(probe "$PLACEHOLDER_BUNDLE" decision)"
else
    fail "placeholder export" "a bundle" "export failed"
fi

# ========================================
# Finding lifecycle
# ========================================

echo ""
echo "Section 3: Finding resolves and links to its fix round"

# clean-complete has one review result (round 0). Adding a round-1 summary
# makes round 1 a round, and a round-1 review result that no longer names the
# finding is the re-review that closes it.
RESOLVED_RUN=$(make_run resolved)
cat > "$RESOLVED_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P1] Handle the empty-string case for AC2 - greeting.py:6-6
  The helper returns None for an empty input.
REVIEW_EOF
cp "$RESOLVED_RUN/round-0-summary.md" "$RESOLVED_RUN/round-1-summary.md"
cat > "$RESOLVED_RUN/round-1-review-result.md" <<'REVIEW_EOF'
No blocking issues remain. The empty-string case is covered.
REVIEW_EOF

RESOLVED_BUNDLE=$(export_run "$RESOLVED_RUN" resolved)
if [[ -n "$RESOLVED_BUNDLE" ]]; then
    assert_equals "a finding absent from a later review resolves" "resolved" \
        "$(probe "$RESOLVED_BUNDLE" finding_statuses)"
    assert_equals "the resolving round is recorded as fix_round" "1" \
        "$(probe "$RESOLVED_BUNDLE" finding_field:fix_round)"
    RESOLVED_REF=$(probe "$RESOLVED_BUNDLE" finding_field:re_review_ref)
    if [[ -n "$RESOLVED_REF" && "$RESOLVED_REF" != "absent" ]]; then
        pass "the re-review evidence is linked (re_review_ref: $RESOLVED_REF)"
    else
        fail "re_review_ref" "an evidence id" "$RESOLVED_REF"
    fi
else
    fail "resolved export" "a bundle" "export failed"
fi

# The complete-after-rework golden Run is a real capture, and what it captured
# is a Run that reached `complete` with its two findings still outstanding: its
# tracker records "Awaiting round 2 Codex review of round 1 fixes" and a
# Verified Round of `pending`, and no round-2 review result was ever written.
# So the coherent reading of it is two open findings and nothing verified --
# not a resolved lifecycle. Asserted here so that stays a recorded property of
# the fixture rather than a silent gap; the resolved path is covered above,
# against a Run that actually has the re-review.
REWORK_LOCAL_RUN=$(make_run rework-local complete-after-rework)
REWORK_LOCAL=$(export_run "$REWORK_LOCAL_RUN" rework-local local-v0)
if [[ -n "$REWORK_LOCAL" ]]; then
    assert_equals "the golden rework Run keeps both findings open" "open,open" \
        "$(probe "$REWORK_LOCAL" finding_statuses)"
    assert_equals "it claims no fix round for either" "absent,absent" \
        "$(probe "$REWORK_LOCAL" finding_field:fix_round)"
    assert_equals "and it does not derive accept" "unverifiable" \
        "$(probe "$REWORK_LOCAL" decision)"
else
    fail "golden rework export" "a bundle" "export failed"
fi

echo ""
echo "Section 4: An unparseable re-review is unverifiable, not resolved"

UNPARSEABLE_RUN=$(make_run unparseable)
cat > "$UNPARSEABLE_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P1] Handle the empty-string case for AC2 - greeting.py:6-6
  The helper returns None for an empty input.
REVIEW_EOF
cp "$UNPARSEABLE_RUN/round-0-summary.md" "$UNPARSEABLE_RUN/round-1-summary.md"
: > "$UNPARSEABLE_RUN/round-1-review-result.md"

UNPARSEABLE_BUNDLE=$(export_run "$UNPARSEABLE_RUN" unparseable)
if [[ -n "$UNPARSEABLE_BUNDLE" ]]; then
    assert_equals "an empty re-review leaves the finding unverifiable" "unverifiable" \
        "$(probe "$UNPARSEABLE_BUNDLE" finding_statuses)"
    assert_equals "no fix round is claimed for it" "absent" \
        "$(probe "$UNPARSEABLE_BUNDLE" finding_field:fix_round)"
    assert_equals "an unverifiable finding blocks accept" "unverifiable" \
        "$(probe "$UNPARSEABLE_BUNDLE" decision)"
else
    fail "unparseable export" "a bundle" "export failed"
fi

echo ""
echo "Section 5: waived requires an explicit Queued or Deferred record"

WAIVED_RUN=$(make_run waived)
cat > "$WAIVED_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P3] Tidy the module docstring - greeting.py:1-1
  Cosmetic only.
REVIEW_EOF
append_table_row "$WAIVED_RUN/goal-tracker.md" "Queued Side Issues" \
    "| [P3] Tidy the module docstring | 0 | Cosmetic only, no AC depends on it | Next docs pass |"

WAIVED_BUNDLE=$(export_run "$WAIVED_RUN" waived)
if [[ -n "$WAIVED_BUNDLE" ]]; then
    assert_equals "a queued finding is waived" "waived" \
        "$(probe "$WAIVED_BUNDLE" finding_statuses)"
    assert_equals "a waived finding does not block accept" "accept" \
        "$(probe "$WAIVED_BUNDLE" decision)"
else
    fail "waived export" "a bundle" "export failed"
fi

# The same finding with no queued record must stay open. Without this the
# waiver rule could be satisfied by anything at all.
UNWAIVED_RUN=$(make_run unwaived)
cat > "$UNWAIVED_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P3] Tidy the module docstring - greeting.py:1-1
  Cosmetic only.
REVIEW_EOF

UNWAIVED_BUNDLE=$(export_run "$UNWAIVED_RUN" unwaived)
if [[ -n "$UNWAIVED_BUNDLE" ]]; then
    assert_equals "the same finding without a queued record stays open" "open" \
        "$(probe "$UNWAIVED_BUNDLE" finding_statuses)"
    assert_equals "an open finding requires changes" "changes_required" \
        "$(probe "$UNWAIVED_BUNDLE" decision)"
else
    fail "unwaived export" "a bundle" "export failed"
fi

# ========================================
# Per-AC status
# ========================================

echo ""
echo "Section 6: A verified AC with a later open finding is partial"

PARTIAL_RUN=$(make_run partial)
cat > "$PARTIAL_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P1] AC2 test does not cover the documented case - test_greeting.py:10-10
  The unittest asserts the wrong string.
REVIEW_EOF

PARTIAL_BUNDLE=$(export_run "$PARTIAL_RUN" partial)
if [[ -n "$PARTIAL_BUNDLE" ]]; then
    assert_equals "the criterion the finding names becomes partial" "partial" \
        "$(probe "$PARTIAL_BUNDLE" ac:ac-2)"
    assert_equals "criteria the finding does not name stay met" "met" \
        "$(probe "$PARTIAL_BUNDLE" ac:ac-1)"
    CONTRADICTING=$(probe "$PARTIAL_BUNDLE" ac_contradicting:ac-2)
    if [[ "$CONTRADICTING" -ge 1 ]]; then
        pass "the partial criterion cites contradicting evidence ($CONTRADICTING refs)"
    else
        fail "partial contradicting evidence" ">= 1 ref" "$CONTRADICTING"
    fi
    assert_equals "a partial criterion requires changes" "changes_required" \
        "$(probe "$PARTIAL_BUNDLE" decision)"
else
    fail "partial export" "a bundle" "export failed"
fi

echo ""
echo "Section 7: Deferral needs a citable Plan Evolution Log row"

# The Explicitly Deferred row cites round 1, and the Plan Evolution Log gains a
# round 1 row, so the deferral is backed by a recorded replan.
DEFERRED_RUN=$(make_run deferred)
append_table_row "$DEFERRED_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 0 | Dropped AC5 from scope | Out of scope after review | AC5 deferred |"
append_table_row "$DEFERRED_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Limit the change surface | AC5 | 0 | Superseded by the round 0 replan | Next milestone |"

DEFERRED_BUNDLE=$(export_run "$DEFERRED_RUN" deferred)
if [[ -n "$DEFERRED_BUNDLE" ]]; then
    assert_equals "a cited deferral derives deferred" "deferred" \
        "$(probe "$DEFERRED_BUNDLE" ac:ac-5)"
    assert_equals "the deferred criterion leaves the required set" "ac-1,ac-2,ac-3,ac-4" \
        "$(probe "$DEFERRED_BUNDLE" required_set)"
    assert_equals "the deferred criterion stays visible" "ac-5" \
        "$(probe "$DEFERRED_BUNDLE" deferred_ac_ids)"
    assert_equals "the deferral carries a replan reference" "yes" \
        "$(probe "$DEFERRED_BUNDLE" deferred_has_replan_ref)"
else
    fail "deferred export" "a bundle" "export failed"
fi

# The same deferral citing a round with no Plan Evolution Log entry must not be
# accepted -- otherwise a criterion can be dropped from the required set with
# no recorded replan behind it.
UNCITED_RUN=$(make_run uncited)
append_table_row "$UNCITED_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Limit the change surface | AC5 | 7 | No replan was recorded for this | Next milestone |"

UNCITED_BUNDLE=$(export_run "$UNCITED_RUN" uncited)
if [[ -n "$UNCITED_BUNDLE" ]]; then
    assert_equals "an uncited deferral is not accepted as deferred" "unverifiable" \
        "$(probe "$UNCITED_BUNDLE" ac:ac-5)"
    assert_equals "it stays in the required set" "ac-1,ac-2,ac-3,ac-4,ac-5" \
        "$(probe "$UNCITED_BUNDLE" required_set)"
    assert_equals "and it costs the Run its accept" "unverifiable" \
        "$(probe "$UNCITED_BUNDLE" decision)"
else
    fail "uncited deferral export" "a bundle" "export failed"
fi

# ========================================
# Profile relativity and the reject rule
# ========================================

echo ""
echo "Section 8: Verdict is relative to the profile's admitted evidence"

# public-v0 omits the Goal Tracker when it carries an absolute home path, which
# takes the completion record with it. The same Run must not carry `met` into
# the thinner profile.
#
# When the tracker itself is the omitted item, the criteria derived from it are
# withheld too, so the criterion is absent rather than listed `unverifiable` --
# test-proof-export.sh pins that as a disclosure rule. What matters here is the
# invariant either way: the thinner profile never inherits `met`, and never
# derives `accept`.
REDACTED_RUN=$(make_run redacted)
printf '\nSee /Users/example/workspace/greeting.py for the local checkout.\n' \
    >> "$REDACTED_RUN/goal-tracker.md"

REDACTED_LOCAL=$(export_run "$REDACTED_RUN" redacted-local local-v0)
REDACTED_PUBLIC=$(export_run "$REDACTED_RUN" redacted-public public-v0)
if [[ -n "$REDACTED_LOCAL" && -n "$REDACTED_PUBLIC" ]]; then
    assert_equals "local-v0 still sees the completion record" "met" \
        "$(probe "$REDACTED_LOCAL" ac:ac-1)"
    REDACTED_STATUSES=$(probe "$REDACTED_PUBLIC" statuses)
    if [[ "$REDACTED_STATUSES" != *met* ]]; then
        pass "public-v0 inherits no met from the fuller profile (statuses: ${REDACTED_STATUSES:-none})"
    else
        fail "redacted profile statuses" "no met status" "$REDACTED_STATUSES"
    fi
    assert_equals "the redacted profile does not derive accept" "unverifiable" \
        "$(probe "$REDACTED_PUBLIC" decision)"
else
    fail "redacted export" "two bundles" "local=[$REDACTED_LOCAL] public=[$REDACTED_PUBLIC]"
fi

# The redaction that #9 names -- an AC listed but unverifiable because the
# profile withheld what would have verified it -- is the case where the tracker
# survives and the round evidence does not. complete-after-rework is that Run:
# its review result carries an absolute path, so public-v0 drops it.
REWORK_RUN=$(make_run rework complete-after-rework)
REWORK_PUBLIC=$(export_run "$REWORK_RUN" rework-public public-v0)
if [[ -n "$REWORK_PUBLIC" ]]; then
    REWORK_STATUSES=$(probe "$REWORK_PUBLIC" statuses)
    assert_equals "an AC whose evidence the profile withheld is unverifiable" \
        "unverifiable" "$REWORK_STATUSES"
    assert_equals "and the Run does not derive accept" "unverifiable" \
        "$(probe "$REWORK_PUBLIC" decision)"
else
    fail "rework public export" "a bundle" "export failed"
fi

echo ""
echo "Section 9: met requires a recorded Verified Round"

# Spec section G: `met` means the row is in Completed and Verified *with a
# Verified Round*. The column was not read at all, so a row still reading
# "pending" -- the literal value the tracker template writes while a round
# awaits review -- produced `met` and `accept` on an unreviewed Run.
PENDING_RUN=$(make_run pending)
python3 - "$PENDING_RUN/goal-tracker.md" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# Completed Round stays 0; only Verified Round becomes pending.
text = re.sub(
    r"^(\| AC[^|]*\|[^|]*\| 0 \|) 0 \|", r"\1 pending |", text, flags=re.MULTILINE
)
open(path, "w", encoding="utf-8").write(text)
PY
if grep -q 'pending' "$PENDING_RUN/goal-tracker.md"; then
    PENDING_BUNDLE=$(export_run "$PENDING_RUN" pending)
    if [[ -n "$PENDING_BUNDLE" ]]; then
        PENDING_STATUSES=$(probe "$PENDING_BUNDLE" statuses)
        if [[ "$PENDING_STATUSES" != *met* ]]; then
            pass "a pending Verified Round never derives met (statuses: $PENDING_STATUSES)"
        else
            fail "pending Verified Round" "no met status" "$PENDING_STATUSES"
        fi
        assert_equals "and the Run does not derive accept" "unverifiable" \
            "$(probe "$PENDING_BUNDLE" decision)"
    else
        fail "pending export" "a bundle" "export failed"
    fi
else
    fail "pending fixture setup" "a pending Verified Round" "the rewrite did not apply"
fi

# A Verified Round only verifies something if the Run recorded that round.
# "999" parses as a round and names none.
UNRECORDED_RUN=$(make_run unrecorded)
python3 - "$UNRECORDED_RUN/goal-tracker.md" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^(\| AC[^|]*\|[^|]*\| 0 \|) 0 \|", r"\1 999 |", text, flags=re.MULTILINE)
open(path, "w", encoding="utf-8").write(text)
PY
UNRECORDED_BUNDLE=$(export_run "$UNRECORDED_RUN" unrecorded)
if [[ -n "$UNRECORDED_BUNDLE" ]]; then
    UNRECORDED_STATUSES=$(probe "$UNRECORDED_BUNDLE" statuses)
    if [[ "$UNRECORDED_STATUSES" != *met* ]]; then
        pass "a Verified Round the Run never recorded does not derive met (statuses: $UNRECORDED_STATUSES)"
    else
        fail "unrecorded Verified Round" "no met status" "$UNRECORDED_STATUSES"
    fi
    assert_equals "and it does not derive accept" "unverifiable" \
        "$(probe "$UNRECORDED_BUNDLE" decision)"
else
    fail "unrecorded round export" "a bundle" "export failed"
fi

echo ""
echo "Section 10: A deferral must be authorized for that criterion"

# Every Run opens with a "| 0 | Initial plan |" Plan Evolution row, so matching
# a deferral on the round alone let any deferral citing round 0 through. The
# replan row has to name the criterion being dropped.
UNRELATED_RUN=$(make_run unrelated)
append_table_row "$UNRELATED_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Skip the scope limit | AC5 | 0 | authorized only by the initial-plan row | later |"

UNRELATED_BUNDLE=$(export_run "$UNRELATED_RUN" unrelated)
if [[ -n "$UNRELATED_BUNDLE" ]]; then
    assert_equals "an unrelated round-0 replan row does not authorize a deferral" \
        "unverifiable" "$(probe "$UNRELATED_BUNDLE" ac:ac-5)"
    assert_equals "the criterion stays in the required set" "ac-1,ac-2,ac-3,ac-4,ac-5" \
        "$(probe "$UNRELATED_BUNDLE" required_set)"
    assert_equals "and no accept is manufactured" "unverifiable" \
        "$(probe "$UNRELATED_BUNDLE" decision)"
else
    fail "unrelated deferral export" "a bundle" "export failed"
fi

# An AC token that lands in a Change or Reason cell is prose, not a declared
# impact. Only the Impact on AC column authorizes.
INCIDENTAL_RUN=$(make_run incidental)
append_table_row "$INCIDENTAL_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 0 | Reworded notes mentioning AC5 | tidy up | - |"
append_table_row "$INCIDENTAL_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Skip the scope limit | AC5 | 0 | authorized only by a prose mention | later |"

INCIDENTAL_BUNDLE=$(export_run "$INCIDENTAL_RUN" incidental)
if [[ -n "$INCIDENTAL_BUNDLE" ]]; then
    assert_equals "an AC named only in a Change cell does not authorize a deferral" \
        "unverifiable" "$(probe "$INCIDENTAL_BUNDLE" ac:ac-5)"
    assert_equals "the criterion stays required" "ac-1,ac-2,ac-3,ac-4,ac-5" \
        "$(probe "$INCIDENTAL_BUNDLE" required_set)"
else
    fail "incidental mention export" "a bundle" "export failed"
fi

# A replan row that names a different criterion at the same round must not
# authorize this one either. Matching the round and requiring *some* named
# criterion is not enough; the row has to name the criterion being dropped.
WRONG_AC_RUN=$(make_run wrong-ac)
append_table_row "$WRONG_AC_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 0 | Reworded the test criterion | Clarity | AC2 wording updated |"
append_table_row "$WRONG_AC_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Skip the scope limit | AC5 | 0 | the round-0 replan names AC2, not AC5 | later |"

WRONG_AC_BUNDLE=$(export_run "$WRONG_AC_RUN" wrong-ac)
if [[ -n "$WRONG_AC_BUNDLE" ]]; then
    assert_equals "a replan naming another criterion does not authorize this one" \
        "unverifiable" "$(probe "$WRONG_AC_BUNDLE" ac:ac-5)"
    assert_equals "it stays in the required set" "ac-1,ac-2,ac-3,ac-4,ac-5" \
        "$(probe "$WRONG_AC_BUNDLE" required_set)"
else
    fail "wrong-AC deferral export" "a bundle" "export failed"
fi

# AC tokens in the Task prose must not defer additional criteria: only the
# Original AC column says what was deferred.
PROSE_RUN=$(make_run prose)
append_table_row "$PROSE_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 0 | Deferred the scope limit | Out of scope after review | AC5 leaves the required set |"
append_table_row "$PROSE_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Defer AC4 work as well | AC5 | 0 | the task text names a second criterion | later |"

PROSE_BUNDLE=$(export_run "$PROSE_RUN" prose)
if [[ -n "$PROSE_BUNDLE" ]]; then
    assert_equals "the criterion in Original AC is deferred" "deferred" \
        "$(probe "$PROSE_BUNDLE" ac:ac-5)"
    assert_equals "the criterion named only in the task prose is not" "met" \
        "$(probe "$PROSE_BUNDLE" ac:ac-4)"
    assert_equals "so only the cited criterion leaves the required set" "ac-1,ac-2,ac-3,ac-4" \
        "$(probe "$PROSE_BUNDLE" required_set)"
else
    fail "prose deferral export" "a bundle" "export failed"
fi

# A round nobody ran authorizes nothing, however consistently the tracker
# talks about it. Two rows agreeing with each other about round 999 removed
# the criterion and produced accept.
GHOST_ROUND_RUN=$(make_run ghost-round)
append_table_row "$GHOST_ROUND_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 999 | Dropped the scope limit | out of scope | AC5 leaves the required set |"
append_table_row "$GHOST_ROUND_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Skip the scope limit | AC5 | 999 | round 999 never happened | later |"

GHOST_ROUND_BUNDLE=$(export_run "$GHOST_ROUND_RUN" ghost-round)
if [[ -n "$GHOST_ROUND_BUNDLE" ]]; then
    assert_equals "a deferral citing a round the Run never ran is not accepted" \
        "unverifiable" "$(probe "$GHOST_ROUND_BUNDLE" ac:ac-5)"
    assert_equals "the criterion stays required" "ac-1,ac-2,ac-3,ac-4,ac-5" \
        "$(probe "$GHOST_ROUND_BUNDLE" required_set)"
    assert_equals "and no accept is manufactured" "unverifiable" \
        "$(probe "$GHOST_ROUND_BUNDLE" decision)"
else
    fail "ghost round export" "a bundle" "export failed"
fi

# Renaming the column the deferral is read from must not let another column
# stand in for it. A table this deriver cannot read is a table problem.
UNLABELLED_RUN=$(make_run unlabelled)
python3 - "$UNLABELLED_RUN/goal-tracker.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    "| Task | Original AC | Deferred Since | Justification | When to Reconsider |",
    "| Task | Owner | Deferred Since | Justification | When to Reconsider |",
)
open(path, "w", encoding="utf-8").write(text)
PY
append_table_row "$UNLABELLED_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 0 | Dropped the scope limit | out of scope | AC5 leaves the required set |"
append_table_row "$UNLABELLED_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Skip the scope limit | AC5 | 0 | AC5 sits in a column named Owner | later |"

UNLABELLED_BUNDLE=$(export_run "$UNLABELLED_RUN" unlabelled)
if [[ -n "$UNLABELLED_BUNDLE" ]]; then
    assert_equals "a deferred table with no Original AC column defers nothing" \
        "ac-1,ac-2,ac-3,ac-4,ac-5" "$(probe "$UNLABELLED_BUNDLE" required_set)"
    assert_equals "and the unreadable table makes the verdict unverifiable" \
        "unverifiable" "$(probe "$UNLABELLED_BUNDLE" decision)"
else
    fail "unlabelled deferred export" "a bundle" "export failed"
fi

echo ""
echo "Section 11: The final round must have been reviewed"

# A Run cannot have exited the loop as `complete` without its last round being
# reviewed, so a missing review there means the delivered work was never
# reviewed at all -- which previously produced no warning and derived accept.
UNREVIEWED_RUN=$(make_run unreviewed)
cp "$UNREVIEWED_RUN/round-0-summary.md" "$UNREVIEWED_RUN/round-1-summary.md"

UNREVIEWED_BUNDLE=$(export_run "$UNREVIEWED_RUN" unreviewed)
if [[ -n "$UNREVIEWED_BUNDLE" ]]; then
    assert_equals "an unreviewed final round does not derive accept" "unverifiable" \
        "$(probe "$UNREVIEWED_BUNDLE" decision)"
    UNREVIEWED_WARNINGS=$(probe "$UNREVIEWED_BUNDLE" warning_reasons)
    if [[ "$UNREVIEWED_WARNINGS" == *profile-required-evidence-missing* ]]; then
        pass "and it warns profile-required-evidence-missing"
    else
        fail "unreviewed final round warning" "profile-required-evidence-missing" "$UNREVIEWED_WARNINGS"
    fi
    # Spec section J lists each round's review result as required evidence and
    # maps missing required evidence to `incomplete`.
    assert_equals "the Bundle is incomplete, not valid" "incomplete" \
        "$(probe "$UNREVIEWED_BUNDLE" integrity)"
else
    fail "unreviewed export" "a bundle" "export failed"
fi

# The summary side of the same contract: a Run cannot have delivered work in a
# round it never summarized, and spec section J lists each round's summary as
# required evidence too.
NO_SUMMARY_RUN=$(make_run no-summary)
cp "$NO_SUMMARY_RUN/round-0-review-result.md" "$NO_SUMMARY_RUN/round-1-review-result.md"

NO_SUMMARY_BUNDLE=$(export_run "$NO_SUMMARY_RUN" no-summary)
if [[ -n "$NO_SUMMARY_BUNDLE" ]]; then
    assert_equals "a final round with no summary does not derive accept" "unverifiable" \
        "$(probe "$NO_SUMMARY_BUNDLE" decision)"
    NO_SUMMARY_WARNINGS=$(probe "$NO_SUMMARY_BUNDLE" warning_reasons)
    if [[ "$NO_SUMMARY_WARNINGS" == *profile-required-evidence-missing* ]]; then
        pass "and it warns profile-required-evidence-missing"
    else
        fail "missing final summary warning" "profile-required-evidence-missing" \
            "$NO_SUMMARY_WARNINGS"
    fi
else
    fail "no-summary export" "a bundle" "export failed"
fi

# Present-but-withheld is not present. A profile that omits the final summary
# while an earlier round's summary stays included satisfies the kind-level
# required-evidence check, so testing only for absence let this export accept.
WITHHELD_RUN=$(make_run withheld)
cp "$WITHHELD_RUN/round-0-summary.md" "$WITHHELD_RUN/round-1-summary.md"
cp "$WITHHELD_RUN/round-0-review-result.md" "$WITHHELD_RUN/round-1-review-result.md"
printf '\nLocal path: /Users/example/private/greeting.py\n' >> "$WITHHELD_RUN/round-1-summary.md"

WITHHELD_BUNDLE=$(export_run "$WITHHELD_RUN" withheld public-v0)
if [[ -n "$WITHHELD_BUNDLE" ]]; then
    assert_equals "an omitted final summary does not derive accept" "unverifiable" \
        "$(probe "$WITHHELD_BUNDLE" decision)"
    assert_equals "and the Bundle is incomplete" "incomplete" \
        "$(probe "$WITHHELD_BUNDLE" integrity)"
else
    fail "withheld summary export" "a bundle" "export failed"
fi

# A recorded round with neither a summary nor a review result carries no
# evidence of what happened in it. The required-evidence check counts kinds
# across the Bundle, so a middle round holding only a contract used to leave
# `accept` at integrity `valid`.
EMPTY_ROUND_RUN=$(make_run empty-round)
cp "$EMPTY_ROUND_RUN/round-0-summary.md" "$EMPTY_ROUND_RUN/round-2-summary.md"
cp "$EMPTY_ROUND_RUN/round-0-review-result.md" "$EMPTY_ROUND_RUN/round-2-review-result.md"
cp "$EMPTY_ROUND_RUN/round-0-contract.md" "$EMPTY_ROUND_RUN/round-1-contract.md"

EMPTY_ROUND_BUNDLE=$(export_run "$EMPTY_ROUND_RUN" empty-round public-v0)
if [[ -n "$EMPTY_ROUND_BUNDLE" ]]; then
    assert_equals "a round with no summary and no review does not derive accept" \
        "unverifiable" "$(probe "$EMPTY_ROUND_BUNDLE" decision)"
    assert_equals "and the Bundle is incomplete" "incomplete" \
        "$(probe "$EMPTY_ROUND_BUNDLE" integrity)"
else
    fail "empty round export" "a bundle" "export failed"
fi

# An intermediate round without a *review* is still normal: work summarized in
# round N and reviewed in round N+1 is reviewed work, and cancel-after-review
# is a real Run shaped exactly that way. Whether that N+1 rule is the intended
# product contract is a spec question, tracked separately; the check above is
# deliberately narrower and only rejects a round with nothing at all.
INTERMEDIATE_RUN=$(make_run intermediate cancel-after-review)
INTERMEDIATE_BUNDLE=$(export_run "$INTERMEDIATE_RUN" intermediate)
if [[ -n "$INTERMEDIATE_BUNDLE" ]]; then
    INTERMEDIATE_WARNINGS=$(probe "$INTERMEDIATE_BUNDLE" warning_reasons)
    if [[ "$INTERMEDIATE_WARNINGS" != *profile-required-evidence-missing* ]]; then
        pass "an unreviewed intermediate round is not flagged (warnings: ${INTERMEDIATE_WARNINGS:-none})"
    else
        fail "intermediate round" "no profile-required-evidence-missing" "$INTERMEDIATE_WARNINGS"
    fi
else
    fail "intermediate export" "a bundle" "export failed"
fi

echo ""
echo "Section 12: A finding queued in Explicitly Deferred is waived too"

# Spec section G names the Queued *and* Deferred tables; only Queued was read.
DEFERRED_WAIVER_RUN=$(make_run deferred-waiver)
cat > "$DEFERRED_WAIVER_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P3] Tidy the module docstring - greeting.py:1-1
  Cosmetic only.
REVIEW_EOF
append_table_row "$DEFERRED_WAIVER_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| [P3] Tidy the module docstring | - | 0 | cosmetic, parked deliberately | Next docs pass |"

DEFERRED_WAIVER_BUNDLE=$(export_run "$DEFERRED_WAIVER_RUN" deferred-waiver)
if [[ -n "$DEFERRED_WAIVER_BUNDLE" ]]; then
    assert_equals "a finding parked in Explicitly Deferred is waived" "waived" \
        "$(probe "$DEFERRED_WAIVER_BUNDLE" finding_statuses)"
else
    fail "deferred waiver export" "a bundle" "export failed"
fi

echo ""
echo "Section 13: reject is never derived"

REJECT_SEEN=""
for bundle in "$CONTROL_BUNDLE" "$PLACEHOLDER_BUNDLE" "$RESOLVED_BUNDLE" \
    "$UNPARSEABLE_BUNDLE" "$WAIVED_BUNDLE" "$UNWAIVED_BUNDLE" "$PARTIAL_BUNDLE" \
    "$DEFERRED_BUNDLE" "$UNCITED_BUNDLE" "$REDACTED_LOCAL" "$REDACTED_PUBLIC"; do
    [[ -n "$bundle" ]] || continue
    if [[ "$(probe "$bundle" decision)" == "reject" ]]; then
        REJECT_SEEN="$bundle"
    fi
done
if [[ -z "$REJECT_SEEN" ]]; then
    pass "no scenario in this suite derives reject"
else
    fail "reject is never derived" "no reject" "$REJECT_SEEN derived reject"
fi

# Every terminal state, including the ones that look worst, must also avoid it.
for fixture in cancel-after-review maxiter-derived stop-derived unexpected-derived; do
    TERMINAL_RUN=$(make_run "terminal-$fixture" "$fixture")
    TERMINAL_BUNDLE=$(export_run "$TERMINAL_RUN" "terminal-$fixture")
    if [[ -n "$TERMINAL_BUNDLE" ]]; then
        TERMINAL_DECISION=$(probe "$TERMINAL_BUNDLE" decision)
        if [[ "$TERMINAL_DECISION" != "reject" ]]; then
            pass "$fixture derives $TERMINAL_DECISION, not reject"
        else
            fail "$fixture verdict" "not reject" "$TERMINAL_DECISION"
        fi
    else
        fail "$fixture export" "a bundle" "export failed"
    fi
done

echo ""
echo "=== Scenario: Goal Tracker shapes the M4 dogfood produced ==="

# Both fixtures below are real Runs captured during the issue #12 dogfood, so
# each assertion is a shape the golden corpus never contained and real Runs
# produce routinely.

# A real plan hard-wraps, so a criterion spans several lines. Reading only the
# bullet line recorded the first line as the whole criterion.
WRAPPED_RUN=$(make_run wrapped-ac wrapped-ac-complete)
WRAPPED_BUNDLE=$(export_run "$WRAPPED_RUN" "wrapped-ac")
if [[ -n "$WRAPPED_BUNDLE" ]]; then
    WRAPPED_TEXT=$(probe "$WRAPPED_BUNDLE" ac_text:ac-1)
    case "$WRAPPED_TEXT" in
        *"whitespace; values keep interior whitespace but lose surrounding whitespace."*)
            pass "a wrapped acceptance criterion keeps its continuation lines"
            ;;
        *)
            fail "wrapped criterion text" \
                "the whole criterion" "$WRAPPED_TEXT"
            ;;
    esac

    # The same Run's Completed and Verified table covers five criteria with one
    # `AC1-AC5` cell. Reading that as `ac-5` alone left four verified criteria
    # `unverifiable` and reported the cell as a malformed reference, which
    # invalidates the mapping and costs the delivery its verdict.
    assert_equals "an AC range in Completed and Verified marks every criterion it names" \
        "met" "$(probe "$WRAPPED_BUNDLE" statuses)"
    assert_equals "a Run whose tracker uses an AC range still derives accept" \
        "accept" "$(probe "$WRAPPED_BUNDLE" decision)"
    assert_equals "an AC range is not reported as a malformed reference" \
        "" "$(probe "$WRAPPED_BUNDLE" warning_reasons)"
else
    fail "wrapped-ac export" "a bundle" "export failed"
fi

# `codex review` cites the file it faults by absolute path, so `public-v0`
# withheld exactly the review results that carried findings. `public-v1`
# publishes the review with those paths masked, and the findings it raised
# read the same as they do under local-v0. (`public-v0` is frozen per
# ADR-0006; the masking revision is a new profile name.)
MASKED_RUN=$(make_run masked-review path-cited-review-complete)
MASKED_LOCAL=$(export_run "$MASKED_RUN" "masked-review-local" local-v0)
MASKED_PUBLIC=$(export_run "$MASKED_RUN" "masked-review-public" public-v1)
if [[ -n "$MASKED_LOCAL" && -n "$MASKED_PUBLIC" ]]; then
    assert_equals "a path-citing review is published under public-v1, not withheld" \
        "masked" "$(probe "$MASKED_PUBLIC" evidence_status:round-1-review-result.md)"
    assert_equals "and the Bundle stays valid" \
        "valid" "$(probe "$MASKED_PUBLIC" integrity)"
    assert_equals "the findings it raised are reported" \
        "4" "$(probe "$MASKED_PUBLIC" finding_count)"
    assert_equals "and they are open, exactly as under local-v0" \
        "$(probe "$MASKED_LOCAL" finding_statuses)" \
        "$(probe "$MASKED_PUBLIC" finding_statuses)"
    # A maintainer holding both Bundles has to be able to line their findings
    # up, so masking must not change a finding's identity.
    assert_equals "masking does not change which findings exist" \
        "$(probe "$MASKED_LOCAL" finding_field:id)" \
        "$(probe "$MASKED_PUBLIC" finding_field:id)"
    # The published bytes are the masked copy, and the source hash stays beside
    # them so a local-v0 Bundle of the same Run can still be matched against it.
    assert_equals "the published review carries no absolute home path" \
        "clean" "$(scan_home_paths "$MASKED_PUBLIC/evidence/round-1-review-result.md")"
    assert_equals "the file hashes to masked_sha256, not to the source hash" \
        "masked" "$(hash_matches "$MASKED_PUBLIC" round-1-review-result.md)"
    assert_equals "the source hash is unchanged from the local-v0 Bundle" \
        "$(probe "$MASKED_LOCAL" evidence_sha256:round-1-review-result.md)" \
        "$(probe "$MASKED_PUBLIC" evidence_sha256:round-1-review-result.md)"
else
    fail "masked-review export" "two bundles" "export failed"
fi

# The withheld path is still reachable, and a finding raised by a review the
# Bundle does not carry must still be recorded -- as `unverifiable`, never
# `open`, and never later cleared (ADR-0005: `open` would claim "no fix has
# been attempted", which withheld evidence cannot establish). An item over
# `max_item_bytes` is truncated, which is "declared but not published" exactly
# as an omission is.
TRUNCATED_RUN=$(make_run truncated-review path-cited-review-complete)
python3 - "$TRUNCATED_RUN/round-1-review-result.md" <<'PY'
import sys

# Padding goes after the review body, so the [P0-9] markers it raised are
# untouched and only the item's publishability changes.
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write("\n" + ("filler line to exceed max_item_bytes\n" * 30000))
PY
TRUNCATED_BUNDLE=$(export_run "$TRUNCATED_RUN" "truncated-review" local-v0)
if [[ -n "$TRUNCATED_BUNDLE" ]]; then
    assert_equals "an unpublished review result still reports the findings it raised" \
        "4" "$(probe "$TRUNCATED_BUNDLE" finding_count)"
    assert_equals "a finding from an unpublished review is unverifiable, never open" \
        "unverifiable,unverifiable,unverifiable,unverifiable" \
        "$(probe "$TRUNCATED_BUNDLE" finding_statuses)"
else
    fail "truncated-review export" "a bundle" "export failed"
fi

# Size is decided on the source bytes, so masking never rescues an oversized
# item and the profile that hides more can never carry the more complete
# Bundle. Before this rule, one long masked-out path published a review under
# the masking profile that local-v0 truncates -- and no Bundle anywhere held
# the source bytes that could corroborate the masking.
OVERSIZED_MASK_RUN=$(make_run oversized-mask path-cited-review-complete)
python3 - "$OVERSIZED_MASK_RUN/round-1-review-result.md" <<'PY'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(
        "Codex review passed. No findings.\n"
        "Source inspected at /Users/" + "a" * 1050000 + "\n"
    )
PY
OVERSIZED_LOCAL=$(export_run "$OVERSIZED_MASK_RUN" oversized-mask-local local-v0)
OVERSIZED_PUBLIC=$(export_run "$OVERSIZED_MASK_RUN" oversized-mask-public public-v1)
if [[ -n "$OVERSIZED_LOCAL" && -n "$OVERSIZED_PUBLIC" ]]; then
    assert_equals "an oversized source is never published masked" \
        "omitted" "$(probe "$OVERSIZED_PUBLIC" evidence_status:round-1-review-result.md)"
    assert_equals "local-v0 truncates the same oversized source" \
        "truncated" "$(probe "$OVERSIZED_LOCAL" evidence_status:round-1-review-result.md)"
    assert_equals "and the thinner profile does not carry the more complete Bundle" \
        "$(probe "$OVERSIZED_LOCAL" integrity)" \
        "$(probe "$OVERSIZED_PUBLIC" integrity)"
else
    fail "oversized-mask export" "two bundles" "export failed"
fi

echo ""
echo "=== Scenario: withheld discovery evidence across later rounds (ADR-0005) ==="

# A later included, clean review must not move a finding whose discovery
# review this Bundle does not carry: the direction is one-way, because
# withheld evidence may show that a problem existed, never that one was
# fixed. Resolution would otherwise be derived from an absence the recipient
# cannot check against the discovery bytes.
LATER_INCLUDED_RUN=$(make_run withheld-then-included path-cited-review-complete)
python3 - "$LATER_INCLUDED_RUN/round-1-review-result.md" <<'PY'
import sys

with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write("\n" + ("filler line to exceed max_item_bytes\n" * 30000))
PY
cat > "$LATER_INCLUDED_RUN/round-2-summary.md" <<'SUMMARY_EOF'
# Round 2 Summary

Addressed the round 1 review remarks and re-ran the suite.
SUMMARY_EOF
cat > "$LATER_INCLUDED_RUN/round-2-review-result.md" <<'REVIEW_EOF'
Codex review passed. No findings.
REVIEW_EOF
LATER_INCLUDED_BUNDLE=$(export_run "$LATER_INCLUDED_RUN" withheld-then-included local-v0)
if [[ -n "$LATER_INCLUDED_BUNDLE" ]]; then
    assert_equals "a later included clean review does not clear a withheld discovery" \
        "unverifiable,unverifiable,unverifiable,unverifiable" \
        "$(probe "$LATER_INCLUDED_BUNDLE" finding_statuses)"
    assert_equals "and the findings are still all recorded" \
        "4" "$(probe "$LATER_INCLUDED_BUNDLE" finding_count)"
else
    fail "withheld-then-included export" "a bundle" "export failed"
fi

# The same Run with the later review also unavailable reaches the same state:
# nothing this Bundle admits can establish any lifecycle for those findings.
LATER_HELD_RUN=$(make_run withheld-then-withheld path-cited-review-complete)
python3 - "$LATER_HELD_RUN/round-1-review-result.md" <<'PY'
import sys

with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write("\n" + ("filler line to exceed max_item_bytes\n" * 30000))
PY
cat > "$LATER_HELD_RUN/round-2-summary.md" <<'SUMMARY_EOF'
# Round 2 Summary

Addressed the round 1 review remarks and re-ran the suite.
SUMMARY_EOF
python3 - "$LATER_HELD_RUN/round-2-review-result.md" <<'PY'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("Codex review passed. No findings.\n")
    handle.write("filler line to exceed max_item_bytes\n" * 30000)
PY
LATER_HELD_BUNDLE=$(export_run "$LATER_HELD_RUN" withheld-then-withheld local-v0)
if [[ -n "$LATER_HELD_BUNDLE" ]]; then
    assert_equals "a later unavailable review leaves a withheld discovery unverifiable" \
        "unverifiable,unverifiable,unverifiable,unverifiable" \
        "$(probe "$LATER_HELD_BUNDLE" finding_statuses)"
else
    fail "withheld-then-withheld export" "a bundle" "export failed"
fi

echo ""
echo "=== Scenario: a malformed marker fails both review readers closed ==="

# The included-review reader refuses partial facts when any marker is
# malformed. The withheld-review reader must refuse them identically, or the
# same Run yields different finding sets across profiles because of a marker
# the parser rejected in both.
MIXED_INCLUDED_RUN=$(make_run mixed-markers-included path-cited-review-complete)
printf -- '- [P?] One marker the parser rejects\n' >> "$MIXED_INCLUDED_RUN/round-1-review-result.md"
MIXED_LOCAL=$(export_run "$MIXED_INCLUDED_RUN" mixed-markers-local local-v0)
MIXED_PUBLIC=$(export_run "$MIXED_INCLUDED_RUN" mixed-markers-public public-v1)

MIXED_HELD_RUN=$(make_run mixed-markers-withheld path-cited-review-complete)
printf -- '- [P?] One marker the parser rejects\n' >> "$MIXED_HELD_RUN/round-1-review-result.md"
python3 - "$MIXED_HELD_RUN/round-1-review-result.md" <<'PY'
import sys

with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write("\n" + ("filler line to exceed max_item_bytes\n" * 30000))
PY
MIXED_HELD=$(export_run "$MIXED_HELD_RUN" mixed-markers-withheld local-v0)
if [[ -n "$MIXED_LOCAL" && -n "$MIXED_PUBLIC" && -n "$MIXED_HELD" ]]; then
    assert_equals "an included review with a malformed marker records no findings" \
        "0" "$(probe "$MIXED_LOCAL" finding_count)"
    assert_equals "the masked profile agrees with the local one" \
        "0" "$(probe "$MIXED_PUBLIC" finding_count)"
    assert_equals "a withheld review with a malformed marker fails closed the same way" \
        "0" "$(probe "$MIXED_HELD" finding_count)"
    MIXED_HELD_WARNINGS=$(probe "$MIXED_HELD" warning_reasons)
    case "$MIXED_HELD_WARNINGS" in
        *unparseable-artifact*)
            pass "and the withheld reader still flags the review unparseable"
            ;;
        *)
            fail "withheld malformed-marker warning" \
                "warning_reasons containing unparseable-artifact" "$MIXED_HELD_WARNINGS"
            ;;
    esac
else
    fail "mixed-markers export" "three bundles" "export failed"
fi

echo ""
echo "=== Scenario: reference grammar hardening from the PR #31 review ==="

# The range boundary is shared with the single-reference grammar, so a range
# ends exactly as a single reference does: `AC1-AC5:` in a table cell is the
# same claim as `AC5:`. Before the boundary was shared, the range failed to
# match, the single scan accepted `ac-5` alone, and the leftover text was
# reported as a malformed reference -- one colon cost the delivery its verdict.
COLON_RANGE_RUN=$(make_run colon-range wrapped-ac-complete)
python3 - "$COLON_RANGE_RUN/goal-tracker.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
updated = text.replace("| AC1-AC5 |", "| AC1-AC5: |", 1)
if updated == text:
    raise SystemExit("fixture cell not found")
open(path, "w", encoding="utf-8").write(updated)
PY
COLON_RANGE_BUNDLE=$(export_run "$COLON_RANGE_RUN" colon-range)
if [[ -n "$COLON_RANGE_BUNDLE" ]]; then
    assert_equals "a range ending in a colon names every criterion it spans" \
        "met" "$(probe "$COLON_RANGE_BUNDLE" statuses)"
    assert_equals "and is not reported as a malformed reference" \
        "" "$(probe "$COLON_RANGE_BUNDLE" warning_reasons)"
else
    fail "colon-range export" "a bundle" "export failed"
fi

# The same boundary in the Explicitly Deferred and Plan Evolution readers: a
# deferral written as a range with a trailing colon defers every criterion
# the range names, and _replan_ac_rounds reads the same colon form out of the
# Impact on AC column -- the deferral is only authorized if both parse.
RANGE_DEFER_RUN=$(make_run range-defer)
append_table_row "$RANGE_DEFER_RUN/goal-tracker.md" "Plan Evolution Log" \
    "| 0 | Dropped AC4 and AC5 from scope | Out of scope after review | AC4-AC5: deferred |"
append_table_row "$RANGE_DEFER_RUN/goal-tracker.md" "Explicitly Deferred" \
    "| Limit the change surface | AC4-AC5: | 0 | Superseded by the round 0 replan | Next milestone |"
RANGE_DEFER_BUNDLE=$(export_run "$RANGE_DEFER_RUN" range-defer)
if [[ -n "$RANGE_DEFER_BUNDLE" ]]; then
    assert_equals "a deferred range with a colon defers each criterion it names" \
        "ac-4,ac-5" "$(probe "$RANGE_DEFER_BUNDLE" deferred_ac_ids)"
    assert_equals "and the range is not reported as malformed" \
        "" "$(probe "$RANGE_DEFER_BUNDLE" warning_reasons)"
else
    fail "range-defer export" "a bundle" "export failed"
fi

# An endpoint past CPython's 4,300-digit int conversion limit used to abort
# the whole export with a conversion error: no Bundle, no structured problem,
# exit 1. An absurd number is a malformed reference like any other.
HUGE_RANGE_RUN=$(make_run huge-range wrapped-ac-complete)
python3 - "$HUGE_RANGE_RUN/goal-tracker.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
updated = text.replace("| AC1-AC5 |", "| AC1-AC" + "9" * 4400 + " |", 1)
if updated == text:
    raise SystemExit("fixture cell not found")
open(path, "w", encoding="utf-8").write(updated)
PY
HUGE_RANGE_BUNDLE=$(export_run "$HUGE_RANGE_RUN" huge-range)
if [[ -n "$HUGE_RANGE_BUNDLE" ]]; then
    assert_equals "an absurd range endpoint is a malformed reference, not an abort" \
        "unparseable-artifact" "$(probe "$HUGE_RANGE_BUNDLE" warning_reasons)"
    assert_equals "and the invalidated mapping derives unverifiable" \
        "unverifiable" "$(probe "$HUGE_RANGE_BUNDLE" decision)"
else
    fail "huge-range export" "a bundle" "export aborted instead of producing one"
fi

# An invalid range is consumed whole. Leaving it in the text let the single
# scan read `ac-1` out of `AC5-AC1` -- an endpoint of a reference the range
# reader had already rejected -- and attach it to a finding.
DESC_REF_RUN=$(make_run descending-ref)
cat > "$DESC_REF_RUN/round-0-review-result.md" <<'REVIEW_EOF'
- [P2] Sort out the AC5-AC1 ordering remark - greeting.py:1-1
  The range in this summary is written backwards.
REVIEW_EOF
DESC_REF_BUNDLE=$(export_run "$DESC_REF_RUN" descending-ref)
if [[ -n "$DESC_REF_BUNDLE" ]]; then
    assert_equals "a descending range in a finding summary names no criterion" \
        "[]" "$(probe "$DESC_REF_BUNDLE" finding_field:ac_refs)"
else
    fail "descending-ref export" "a bundle" "export failed"
fi

echo ""
echo "=== Scenario: Markdown structure never joins a criterion ==="

# A criterion folds its hard-wrapped continuation lines and nothing else.
# Before the structural flushes, a thematic break, a nested heading, prose
# after them, a nested list, a table, or a multiline comment following an AC
# with no blank separator was absorbed into the criterion text -- changing the
# immutable criterion the Acceptance Matrix attests to and its `text_sha256`.
STRUCTURED_RUN=$(make_run structured-criteria)
python3 - "$STRUCTURED_RUN/goal-tracker.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = """1. AC1: `greeting.py` exports a function `greeting()` that returns exactly the string `"hello"`.
2. AC2: `test_greeting.py` verifies `greeting()` using the `unittest` module.
3. AC3: The implementation and test files are committed to git before review begins.
4. AC4: Only the Python standard library is used (no third-party dependencies).
5. AC5: The change is limited to the greeting module and its test (no unrelated files touched)."""
new = """1. AC1: `greeting.py` exports a function `greeting()` that returns exactly
the string `"hello"`.
---
#### Reviewer notes
This prose explains the list and must not join any criterion.
2. AC2: `test_greeting.py` verifies `greeting()` using the `unittest` module.
   - a nested checklist entry that is structure, not a criterion
   + a plus-marker nested entry that is structure just the same
   nested continuation that must stay out as well
3. AC3: The implementation and test files are committed to git before review begins.
Reviewer heading
====
prose under a setext heading that must not join the criterion
<!--
a multiline comment between items
must not fold into any criterion
-->
4. AC4: Only the Python standard library is used (no third-party dependencies).
> a block quote interrupting the paragraph, per CommonMark
| noise | table |
|-------|-------|
5. AC5: The change is limited to the greeting module and its test (no unrelated files touched).
<details>
<summary>collapsed commentary</summary>
hidden commentary that must not join any criterion
</details>"""
if old not in text:
    raise SystemExit("fixture criteria not found")
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
STRUCTURED_BUNDLE=$(export_run "$STRUCTURED_RUN" structured-criteria)
if [[ -n "$STRUCTURED_BUNDLE" ]]; then
    assert_equals "a flush-left hard wrap still folds into its criterion" \
        '`greeting.py` exports a function `greeting()` that returns exactly the string `"hello"`.' \
        "$(probe "$STRUCTURED_BUNDLE" ac_text:ac-1)"
    assert_equals "a nested list and its continuation stay out of the criterion" \
        '`test_greeting.py` verifies `greeting()` using the `unittest` module.' \
        "$(probe "$STRUCTURED_BUNDLE" ac_text:ac-2)"
    assert_equals "a setext heading and its underline stay out of the criterion" \
        'The implementation and test files are committed to git before review begins.' \
        "$(probe "$STRUCTURED_BUNDLE" ac_text:ac-3)"
    assert_equals "a block quote stays out of the criterion" \
        'Only the Python standard library is used (no third-party dependencies).' \
        "$(probe "$STRUCTURED_BUNDLE" ac_text:ac-4)"
    assert_equals "an HTML block and its content stay out of the criterion" \
        'The change is limited to the greeting module and its test (no unrelated files touched).' \
        "$(probe "$STRUCTURED_BUNDLE" ac_text:ac-5)"
    assert_equals "structure between items leaves five clean criteria" \
        "met" "$(probe "$STRUCTURED_BUNDLE" statuses)"
    assert_equals "and the Run still derives accept" \
        "accept" "$(probe "$STRUCTURED_BUNDLE" decision)"
else
    fail "structured-criteria export" "a bundle" "export failed"
fi

echo ""
echo "========================================"
echo "Proof Verdict Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
echo -e "${RED}Some tests failed!${NC}"
exit 1
