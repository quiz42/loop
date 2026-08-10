#!/usr/bin/env bash
# End-to-end verifier coverage for Proof Bundles and profile policy enforcement.

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
loop proof export --run "$RUN_DIR" --profile local-v0 --out "$TEST_DIR/clean" >/dev/null 2>&1
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

ALTERNATE_VERIFIER="$TEST_DIR/alternate-verifier"
mkdir -p "$ALTERNATE_VERIFIER/scripts"
cp -R "$PROJECT_ROOT/proof" "$ALTERNATE_VERIFIER/proof"
cp "$PROJECT_ROOT/scripts/proof-verify.py" "$ALTERNATE_VERIFIER/scripts/proof-verify.py"
python3 - "$ALTERNATE_VERIFIER/proof/explorer/app.js" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes() + b"x" * (11 * 1024 * 1024))
PY
alternate_report=$(python3 "$ALTERNATE_VERIFIER/scripts/proof-verify.py" "$TEST_DIR/clean" --json)
alternate_status=$?
assert_exit "verification uses the received Bundle's Explorer bytes" 0 "$alternate_status"
if python3 - "$alternate_report" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["status"] == "valid"
assert not any(item.get("reason") == "size-budget-exceeded" for item in report["warnings"])
PY
then
    pass "a verifier installation's changed Explorer assets do not change Bundle results"
else
    fail "verifier Explorer size isolation" "valid with no installation-dependent size warning" "$alternate_report"
fi

CANCEL_RUN_DIR="$TEST_DIR/cancel-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/cancel-after-review" "$CANCEL_RUN_DIR"
loop proof export --run "$CANCEL_RUN_DIR" --profile local-v0 --out "$TEST_DIR/cancel" >/dev/null 2>&1
cancel_setup_status=$?
assert_exit "cancel Run exports for verification" 0 "$cancel_setup_status"
cancel_report=$(loop proof verify "$TEST_DIR/cancel" --json)
cancel_verify_status=$?
assert_exit "cancel Bundle verifies with intact integrity" 0 "$cancel_verify_status"
assert_report "cancel Bundle reports valid JSON" "$cancel_report" valid
if python3 - "$cancel_report" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert not any(warning.get("target") == ".cancel-requested" for warning in report["warnings"])
PY
then
    pass "cancel verification has no cancellation-marker warning"
else
    fail "cancel verification warnings" "no warning targeting .cancel-requested" "unexpected cancellation-marker warning"
fi

TRUNCATED_RUN_DIR="$TEST_DIR/truncated-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$TRUNCATED_RUN_DIR"
python3 - "$TRUNCATED_RUN_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes() + b"x" * 1048577)
PY
loop proof export --run "$TRUNCATED_RUN_DIR" --profile local-v0 --out "$TEST_DIR/truncated" >/dev/null 2>&1
truncated_setup_status=$?
assert_exit "truncated required-evidence Run exports for verification" 0 "$truncated_setup_status"
truncated_report=$(loop proof verify "$TEST_DIR/truncated" --json)
truncated_verify_status=$?
assert_exit "truncated required evidence is incomplete" 2 "$truncated_verify_status"
assert_report "truncated required evidence names the missing profile kind" "$truncated_report" incomplete profile-required-evidence-missing

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
if python3 - "$evidence_report" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert not any(
    reason.get("reason") == "integrity-status-mismatch"
    for reason in report["reasons"]
)
PY
then
    pass "an independent invalid finding suppresses integrity-status mismatch noise"
else
    fail "integrity-status mismatch suppression" "no secondary mismatch reason" "$evidence_report"
fi

cp -R "$TEST_DIR/clean" "$TEST_DIR/integrity-status-mismatch"
python3 - "$TEST_DIR/integrity-status-mismatch/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
assert bundle["integrity"]["status"] == "valid"
bundle["integrity"]["status"] = "incomplete"
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
status_mismatch_report=$(loop proof verify "$TEST_DIR/integrity-status-mismatch" --json)
status_mismatch_status=$?
assert_exit "declared integrity status mismatch is invalid" 3 "$status_mismatch_status"
assert_report "integrity status mismatch has a dedicated reason" "$status_mismatch_report" invalid integrity-status-mismatch
if python3 - "$status_mismatch_report" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert any(
    reason.get("reason") == "integrity-status-mismatch"
    and reason.get("target") == "integrity.status"
    for reason in report["reasons"]
)
assert not any(
    reason.get("reason") == "schema-violation"
    and reason.get("target") == "integrity.status"
    for reason in report["reasons"]
)
PY
then
    pass "integrity status mismatch identifies the declared status field"
else
    fail "integrity status mismatch detail" "dedicated integrity.status reason without schema violation" "$status_mismatch_report"
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

# A review-phase round owes no builder summary, so a Bundle that relabels an
# implementation round as one is claiming an exemption from the round-evidence
# rule. The claim is re-derived from the published .review-phase-started marker
# rather than read off the manifest, so re-hashing proof_id does not carry it.
cp -R "$TEST_DIR/clean" "$TEST_DIR/round-kind-tamper"
python3 - "$TEST_DIR/round-kind-tamper/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
assert bundle["run"]["rounds"][0]["kind"] == "implementation"
bundle["run"]["rounds"][0]["kind"] = "review_phase"
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
round_kind_report=$(loop proof verify "$TEST_DIR/round-kind-tamper" --json)
round_kind_status=$?
assert_exit "a re-hashed round kind claim is still invalid" 3 "$round_kind_status"
assert_report "round kind mismatch is actionable" "$round_kind_report" invalid schema-violation
if [[ "$round_kind_report" == *'run.rounds[0].kind'* ]]; then
    pass "round kind mismatch names the round it disagrees about"
else
    fail "round kind mismatch target" "run.rounds[0].kind" "$round_kind_report"
fi

# The same for the coverage edge: which review covers a round is derived, so
# naming a different one does not make it so.
cp -R "$TEST_DIR/clean" "$TEST_DIR/round-coverage-tamper"
python3 - "$TEST_DIR/round-coverage-tamper/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
assert bundle["run"]["rounds"][0]["reviewed_by"] == 0
bundle["run"]["rounds"][0]["reviewed_by"] = 7
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
round_coverage_report=$(loop proof verify "$TEST_DIR/round-coverage-tamper" --json)
round_coverage_status=$?
assert_exit "a re-hashed coverage claim is still invalid" 3 "$round_coverage_status"
assert_report "coverage mismatch is actionable" "$round_coverage_report" invalid schema-violation

cp -R "$TEST_DIR/clean" "$TEST_DIR/missing-evidence"
rm "$TEST_DIR/missing-evidence/evidence/plan.md"
missing_report=$(loop proof verify "$TEST_DIR/missing-evidence" --json)
missing_status=$?
assert_exit "missing included Evidence is invalid" 3 "$missing_status"
assert_report "missing Evidence names missing-file" "$missing_report" invalid missing-file
# The spec's Testing Decisions require "the report naming the specific target"
# for all three tampering cases. The hash-mismatch and proof-id-mismatch cases
# check it; this one did not, so blanking the file name left the suite green.
if [[ "$missing_report" == *'"target": "plan.md"'* ]]; then
    pass "missing-file names the absent file"
else
    fail "missing-file target" "plan.md" "$missing_report"
fi

echo "=== Test: the schema phase rejects, reports, and short-circuits ==="

# `schema-violation` was asserted only where a hand-rolled structural check
# raises it. The schema engine's own rejection -- the spec table's actual
# definition of the code -- never reached verify in any test: instrumenting
# validate() showed zero schema rejections across all 71 calls the suites make,
# and `if not schema_result.is_valid:` could be switched to `if False:` with
# every suite green.
cp -R "$TEST_DIR/clean" "$TEST_DIR/schema-invalid"
python3 - "$TEST_DIR/schema-invalid/proof.json" <<'PY'
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
# A required property, so the failure comes from the schema itself rather than
# from any of the validator's own consistency checks.
del bundle["run"]["terminal_state"]
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
schema_report=$(loop proof verify "$TEST_DIR/schema-invalid" --json)
schema_status=$?
assert_exit "a schema-invalid manifest is invalid" 3 "$schema_status"
assert_report "schema rejection is reported as schema-violation" \
    "$schema_report" invalid schema-violation
if [[ "$schema_report" == *'"target": "$.run"'* ]]; then
    pass "the schema violation names the offending JSON pointer"
else
    fail "schema violation target" '"$.run"' "$schema_report"
fi

# Validation order (spec section J): schema first, and the schema phase is the
# only one of the seven that short-circuits -- every later phase accumulates
# reasons. So this is the one assertion that can observe the documented order
# at all: a Bundle that is both schema-invalid and missing an evidence file
# must report only the schema failure.
cp -R "$TEST_DIR/schema-invalid" "$TEST_DIR/schema-first"
rm "$TEST_DIR/schema-first/evidence/plan.md"
schema_first_report=$(loop proof verify "$TEST_DIR/schema-first" --json)
assert_exit "a doubly-damaged Bundle is invalid" 3 "$?"
if [[ "$schema_first_report" == *schema-violation* && "$schema_first_report" != *missing-file* ]]; then
    pass "the schema phase short-circuits before file existence is checked"
else
    fail "schema-first ordering" "schema-violation and no missing-file" "$schema_first_report"
fi

# Bytes that are not JSON at all reach the same reason from a different branch,
# and no test anywhere corrupted proof.json.
cp -R "$TEST_DIR/clean" "$TEST_DIR/unparseable-manifest"
printf 'this is not json\n' > "$TEST_DIR/unparseable-manifest/proof.json"
unparseable_report=$(loop proof verify "$TEST_DIR/unparseable-manifest" --json)
unparseable_status=$?
assert_exit "an unreadable proof.json is invalid" 3 "$unparseable_status"
assert_report "an unreadable proof.json is a schema-violation" \
    "$unparseable_report" invalid schema-violation
if [[ "$unparseable_report" == *'Cannot parse proof.json'* ]]; then
    pass "and the detail says the manifest could not be parsed"
else
    fail "unparseable manifest detail" "Cannot parse proof.json" "$unparseable_report"
fi

# The third producer: a profile name the Bundle pins but the verifier cannot
# resolve. Also unexercised.
cp -R "$TEST_DIR/clean" "$TEST_DIR/unknown-profile"
python3 - "$TEST_DIR/unknown-profile/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["profile"]["name"] = "no-such-profile-v9"
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
unknown_profile_report=$(loop proof verify "$TEST_DIR/unknown-profile" --json)
unknown_profile_status=$?
assert_exit "an unresolvable profile is invalid" 3 "$unknown_profile_status"
assert_report "an unresolvable profile is a schema-violation" \
    "$unknown_profile_report" invalid schema-violation
if [[ "$unknown_profile_report" == *'"target": "profile.name"'* ]]; then
    pass "and it names profile.name"
else
    fail "unknown profile target" "profile.name" "$unknown_profile_report"
fi

loop proof export --run "$RUN_DIR" --profile public-v0 --out "$TEST_DIR/public" >/dev/null 2>&1
public_setup_status=$?
assert_exit "public Bundle exports for policy verification" 0 "$public_setup_status"

cp -R "$TEST_DIR/public" "$TEST_DIR/public-event-omitted-ref"
python3 - "$TEST_DIR/public-event-omitted-ref/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
omitted = next(item for item in bundle["evidence"] if item["status"] == "omitted")
setup = next(event for event in bundle["run"]["events"] if event["kind"] == "setup")
setup["evidence_refs"] = [omitted["id"]]
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
event_ref_report=$(loop proof verify "$TEST_DIR/public-event-omitted-ref" --json)
event_ref_status=$?
assert_exit "event evidence references require included files" 3 "$event_ref_status"
assert_report "event evidence reference violation is actionable" "$event_ref_report" invalid schema-violation

cp -R "$TEST_DIR/public" "$TEST_DIR/public-omitted-evidence-leak"
mkdir -p "$TEST_DIR/public-omitted-evidence-leak/evidence"
cp "$RUN_DIR/round-0-prompt.md" "$TEST_DIR/public-omitted-evidence-leak/evidence/round-0-prompt.md"
omitted_evidence_report=$(loop proof verify "$TEST_DIR/public-omitted-evidence-leak" --json)
omitted_evidence_status=$?
assert_exit "an omitted public Evidence file must not be present" 3 "$omitted_evidence_status"
assert_report "omitted public Evidence leak is actionable" "$omitted_evidence_report" invalid profile-violation

cp -R "$TEST_DIR/clean" "$TEST_DIR/arbitrary-omission-tamper"
python3 - "$TEST_DIR/arbitrary-omission-tamper" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

bundle_dir = Path(sys.argv[1])
proof_path = bundle_dir / "proof.json"
bundle = json.loads(proof_path.read_text(encoding="utf-8"))
item = next(item for item in bundle["evidence"] if item["path"] == "round-0-contract.md")
item["status"] = "omitted"
item["omitted_reason"] = "profile-redaction"
(bundle_dir / "evidence" / item["path"]).unlink()
bundle["disclosure"]["omitted"].append(
    {"path": item["path"], "reason": item["omitted_reason"]}
)
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
proof_path.write_text(json.dumps(bundle, ensure_ascii=False, sort_keys=True), encoding="utf-8")
PY
arbitrary_omission_report=$(loop proof verify "$TEST_DIR/arbitrary-omission-tamper" --json)
arbitrary_omission_status=$?
assert_exit "a profile cannot arbitrarily omit local Evidence" 3 "$arbitrary_omission_status"
assert_report "arbitrary omission is a profile violation" "$arbitrary_omission_report" invalid profile-violation

cp -R "$TEST_DIR/public" "$TEST_DIR/public-policy-tamper"
python3 - "$RUN_DIR" "$TEST_DIR/public-policy-tamper" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

run_dir, bundle_dir = map(Path, sys.argv[1:])
proof_path = bundle_dir / "proof.json"
bundle = json.loads(proof_path.read_text(encoding="utf-8"))
item = next(item for item in bundle["evidence"] if item["path"] == "round-0-prompt.md")
item["status"] = "included"
item["omitted_reason"] = None
destination = bundle_dir / "evidence" / item["path"]
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes((run_dir / item["path"]).read_bytes())
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
proof_path.write_text(json.dumps(bundle, ensure_ascii=False, sort_keys=True), encoding="utf-8")
PY
public_policy_report=$(loop proof verify "$TEST_DIR/public-policy-tamper" --json)
public_policy_status=$?
assert_exit "a recomputed public Bundle cannot retain a prompt" 3 "$public_policy_status"
assert_report "public profile policy violation is actionable" "$public_policy_report" invalid profile-violation

cp -R "$TEST_DIR/public" "$TEST_DIR/public-path-tamper"
python3 - "$TEST_DIR/public-path-tamper/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["specification"]["goal"] = "Leaked path: /Users/public-profile/private"
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
public_path_report=$(loop proof verify "$TEST_DIR/public-path-tamper" --json)
public_path_status=$?
assert_exit "a recomputed public Bundle cannot contain a home path" 3 "$public_path_status"
assert_report "public path leak is a profile violation" "$public_path_report" invalid profile-violation

commit_secret='api_key=commit_subject_secret_123456789'
cp -R "$TEST_DIR/public" "$TEST_DIR/public-commit-secret-tamper"
python3 - "$TEST_DIR/public-commit-secret-tamper/proof.json" "$commit_secret" <<'PY'
import hashlib
import json
import sys

path, secret = sys.argv[1:]
bundle = json.load(open(path, encoding="utf-8"))
bundle["commits"] = [
    {
        "sha": "a" * 40,
        "subject": secret,
        "authored_at": "2026-08-03T00:00:00Z",
        "author_name": "Proof Test",
    }
]
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
commit_secret_report=$(loop proof verify "$TEST_DIR/public-commit-secret-tamper" --json)
commit_secret_status=$?
assert_exit "public verification rejects secrets in commit metadata" 3 "$commit_secret_status"
assert_report "commit metadata secret is a profile violation" "$commit_secret_report" invalid profile-violation
if [[ "$commit_secret_report" != *"$commit_secret"* ]]; then
    pass "commit metadata verification does not echo the secret value"
else
    fail "commit metadata verification redaction" "no secret value in verifier report" "$commit_secret_report"
fi

REVIEWED_BEHIND_RUN="$TEST_DIR/reviewed-behind-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$REVIEWED_BEHIND_RUN"
python3 - "$REVIEWED_BEHIND_RUN/complete-state.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"^head_commit: .*$", "head_commit: " + "f" * 40, text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
loop proof export --run "$REVIEWED_BEHIND_RUN" --profile local-v0 --out "$TEST_DIR/reviewed-behind" >/dev/null 2>&1
reviewed_behind_setup_status=$?
assert_exit "reviewed-behind Bundle exports for verification" 0 "$reviewed_behind_setup_status"
cp -R "$TEST_DIR/reviewed-behind" "$TEST_DIR/reviewed-behind-warning-tamper"
python3 - "$TEST_DIR/reviewed-behind-warning-tamper/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["integrity"]["compile_warnings"] = [
    warning
    for warning in bundle["integrity"]["compile_warnings"]
    if warning["reason"] != "reviewed-commit-behind-head"
]
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
reviewed_behind_report=$(loop proof verify "$TEST_DIR/reviewed-behind-warning-tamper" --json)
reviewed_behind_status=$?
assert_exit "reviewed-behind Bundle remains valid" 0 "$reviewed_behind_status"
if python3 - "$reviewed_behind_report" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["status"] == "valid"
assert any(
    warning.get("reason") == "reviewed-commit-behind-head"
    and warning.get("target") == "source.reviewed_commit"
    for warning in report["warnings"]
)
PY
then
    pass "validator restores the reviewed-head badge warning"
else
    fail "reviewed-head badge warning" "valid report with reviewed-commit-behind-head warning" "$reviewed_behind_report"
fi

UNKNOWN_COMMITS_RUN="$TEST_DIR/unknown-commits-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$UNKNOWN_COMMITS_RUN"
python3 - "$UNKNOWN_COMMITS_RUN/complete-state.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"^head_commit: .*\n", "", text, flags=re.MULTILINE)
text = re.sub(r"^reviewed_commit: .*\n", "", text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
loop proof export --run "$UNKNOWN_COMMITS_RUN" --profile local-v0 --out "$TEST_DIR/unknown-commits" >/dev/null 2>&1
unknown_commits_setup_status=$?
assert_exit "unknown-commit Bundle exports for verification" 0 "$unknown_commits_setup_status"
cp -R "$TEST_DIR/unknown-commits" "$TEST_DIR/unknown-commits-warning-tamper"
python3 - "$TEST_DIR/unknown-commits-warning-tamper/proof.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["integrity"]["compile_warnings"] = [
    warning
    for warning in bundle["integrity"]["compile_warnings"]
    if warning["reason"] not in {"head-commit-unknown", "reviewed-commit-unknown"}
]
payload = dict(bundle)
payload.pop("proof_id", None)
payload.pop("transport", None)
bundle["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
with open(path, "w", encoding="utf-8") as output:
    json.dump(bundle, output, ensure_ascii=False, sort_keys=True)
PY
unknown_commits_report=$(loop proof verify "$TEST_DIR/unknown-commits-warning-tamper" --json)
unknown_commits_status=$?
assert_exit "unknown commits remain incomplete" 2 "$unknown_commits_status"
if python3 - "$unknown_commits_report" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["status"] == "incomplete"
reasons = {warning.get("reason") for warning in report["warnings"]}
assert {"head-commit-unknown", "reviewed-commit-unknown"} <= reasons
PY
then
    pass "validator restores unknown-commit completeness warnings"
else
    fail "unknown commit warnings" "incomplete report with both unknown-commit warnings" "$unknown_commits_report"
fi

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
