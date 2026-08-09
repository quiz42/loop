#!/usr/bin/env bash
# End-to-end export coverage for Proof export profiles and privacy behavior.

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
SERVER_PID=""
cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
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

if [[ -f "$TEST_DIR/bundle-a/proof.json" && -f "$TEST_DIR/bundle-a/evidence/plan.md" && -f "$TEST_DIR/bundle-a/proof-data.js" && -f "$TEST_DIR/bundle-a/index.html" && -f "$TEST_DIR/bundle-a/app.js" && -f "$TEST_DIR/bundle-a/styles.css" ]]; then
    pass "bundle contains manifest, offline Explorer, display data, and raw evidence"
else
    fail "bundle contents" "proof.json, proof-data.js, index.html, app.js, styles.css, and evidence/plan.md" "$output"
fi

if python3 - "$TEST_DIR/bundle-a/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
assert bundle["profile"]["name"] == "public-v1"
assert bundle["run"]["terminal_state"] == "complete"
assert bundle["run"]["rounds"] == [{"index": 0}]
assert bundle["proof_id"].startswith("sha256:")
assert bundle["integrity"]["status"] == "valid"
verdict_event = next(event for event in bundle["run"]["events"] if event["kind"] == "mainline_verdict")
assert verdict_event["round"] == 0
assert verdict_event["verdict"] == "advanced"
assert verdict_event["evidence_refs"]
plan_event = next(event for event in bundle["run"]["events"] if event["kind"] == "plan_evolution")
assert plan_event["round"] == 0
assert plan_event["evidence_refs"]
PY
then
    pass "manifest defaults to the public profile and records completed Run facts"
else
    fail "manifest Run facts" "public-v1 with only completed round 0" "unexpected manifest"
fi

if python3 - "$PROJECT_ROOT" "$TEST_DIR/bundle-a/proof.json" "$TEST_DIR/bundle-a/proof-data.js" "$TEST_DIR/bundle-a/index.html" "$TEST_DIR/bundle-a/app.js" "$TEST_DIR/bundle-a/styles.css" <<'PY'
import hashlib
import json
import sys
from copy import deepcopy
from pathlib import Path

def proof_id_of(document):
    """Recompute the Bundle identity without importing the product.

    The spec's Testing Decisions keep the CLI subprocess as the only seam these
    suites touch, so the identity is recomputed here rather than imported --
    which also makes this an independent check of the rule rather than a
    comparison of the implementation with itself.
    """
    payload = dict(document)
    payload.pop("proof_id", None)
    payload.pop("transport", None)
    return "sha256:" + hashlib.sha256(
        json.dumps(
            payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    ).hexdigest()


proof = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
display_path = Path(sys.argv[3])
expected_display = (
    "window.PROOF = "
    + json.dumps(proof, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    + ";\n"
).encode("utf-8")
assert display_path.read_bytes() == expected_display
index = Path(sys.argv[4]).read_text(encoding="utf-8")
app = Path(sys.argv[5]).read_text(encoding="utf-8")
styles = Path(sys.argv[6]).read_text(encoding="utf-8")
asset_hashes = proof["explorer"]["assets"]
assert set(asset_hashes) == {"index.html", "app.js", "styles.css"}
for name, path in {
    "index.html": Path(sys.argv[4]),
    "app.js": Path(sys.argv[5]),
    "styles.css": Path(sys.argv[6]),
}.items():
    assert asset_hashes[name] == "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
assert proof_id_of(proof) == proof["proof_id"]
asset_mutation = deepcopy(proof)
asset_mutation["explorer"]["assets"]["index.html"] = "sha256:" + "0" * 64
assert proof_id_of(asset_mutation) != proof["proof_id"]
assert '<script src="proof-data.js"></script>' in index
assert '<script src="app.js"></script>' in index
assert 'window.PROOF' in app
assert 'fetch(' not in app
assert '@import' not in styles
assert 'http://' not in styles and 'https://' not in styles
assert 'event.stall_count' in app
assert 'event.last_mainline_verdict' in app
assert 'Affected acceptance criteria' in app
assert "Packaged display, not live verification." in index
assert "function classFragment" in app
assert 'replace(/[^a-z0-9-]/gi, "-")' in app
assert 'timeline-event--" + classFragment(event.kind, "event")' in app
assert ".evidence-link--truncated" in styles
assert "replaceChildren" not in app
assert "navigation.forEach" not in app
PY
then
    pass "Explorer assets are attested, deterministic, offline, and render with safe compatibility guards"
else
    fail "Explorer packaging" "attested assets and exact proof-data.js derivation" "unexpected Explorer asset content"
fi

FAKE_OPEN_BIN="$TEST_DIR/fake-open-bin"
OPEN_CAPTURE="$TEST_DIR/opened-url"
mkdir -p "$FAKE_OPEN_BIN"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "$LOOP_PROOF_OPEN_CAPTURE"\n' > "$FAKE_OPEN_BIN/open"
chmod +x "$FAKE_OPEN_BIN/open"
cp "$FAKE_OPEN_BIN/open" "$FAKE_OPEN_BIN/xdg-open"
chmod +x "$FAKE_OPEN_BIN/xdg-open"

assert_open_rejected_without_launcher() {
    local name="$1"
    local bundle="$2"
    local expected_fragment="$3"
    local open_output
    local open_status

    rm -f "$OPEN_CAPTURE"
    open_output=$( (
            export PATH="$FAKE_OPEN_BIN:$PATH"
            export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
            loop proof open "$bundle"
        ) 2>&1 )
    open_status=$?
    assert_exit "$name" 1 "$open_status"
    if [[ "$open_output" == *"$expected_fragment"* ]]; then
        pass "$name reports the renderer preflight failure"
    else
        fail "$name error" "$expected_fragment" "$open_output"
    fi
    if [[ ! -e "$OPEN_CAPTURE" ]]; then
        pass "$name never invokes the system launcher"
    else
        fail "$name launcher guard" "no launcher invocation" "$(<"$OPEN_CAPTURE")"
    fi
}

open_output=$( (
        export PATH="$FAKE_OPEN_BIN:$PATH"
        export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
        loop proof open "$TEST_DIR/bundle-a"
    ) 2>&1 )
open_status=$?
assert_exit "proof open launches the packaged file Explorer" 0 "$open_status"
expected_file_url=$(python3 - "$TEST_DIR/bundle-a/index.html" <<'PY'
import sys
from pathlib import Path

print(Path(sys.argv[1]).resolve().as_uri())
PY
)
if [[ -f "$OPEN_CAPTURE" && "$(<"$OPEN_CAPTURE")" == "$expected_file_url" ]]; then
    pass "proof open uses the file URL for index.html"
else
    fail "proof open file URL" "$expected_file_url" "${open_output:-no launcher output}"
fi

INVALID_OPEN_DIR="$TEST_DIR/invalid-open-bundle"
cp -R "$TEST_DIR/bundle-a" "$INVALID_OPEN_DIR"
python3 - "$INVALID_OPEN_DIR/proof.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
bundle = json.loads(path.read_text(encoding="utf-8"))
bundle["proof_id"] = "sha256:" + ("0" * 64)
path.write_text(
    json.dumps(bundle, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
    encoding="utf-8",
)
PY
assert_open_rejected_without_launcher \
    "proof open rejects an invalid Bundle before launch" \
    "$INVALID_OPEN_DIR" \
    "validation is invalid"

for renderer_asset in index.html app.js styles.css; do
    TAMPERED_RENDERER_DIR="$TEST_DIR/tampered-$renderer_asset"
    cp -R "$TEST_DIR/bundle-a" "$TAMPERED_RENDERER_DIR"
    printf '\n// renderer tamper\n' >> "$TAMPERED_RENDERER_DIR/$renderer_asset"
    assert_open_rejected_without_launcher \
        "proof open rejects a tampered $renderer_asset" \
        "$TAMPERED_RENDERER_DIR" \
        "asset hash mismatch: $renderer_asset"
done

TAMPERED_DISPLAY_DIR="$TEST_DIR/tampered-proof-data"
cp -R "$TEST_DIR/bundle-a" "$TAMPERED_DISPLAY_DIR"
printf '\n// display-only tamper\n' >> "$TAMPERED_DISPLAY_DIR/proof-data.js"
assert_open_rejected_without_launcher \
    "proof open rejects tampered proof-data.js" \
    "$TAMPERED_DISPLAY_DIR" \
    "proof-data.js does not exactly match proof.json"

rm -f "$OPEN_CAPTURE"
server_preflight_output=$( (
        export PATH="$FAKE_OPEN_BIN:$PATH"
        export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
        loop proof open --server "$TAMPERED_DISPLAY_DIR"
    ) 2>&1 )
server_preflight_status=$?
assert_exit "proof open --server applies renderer preflight before listening" 1 "$server_preflight_status"
if [[ "$server_preflight_output" == *"proof-data.js does not exactly match proof.json"* && "$server_preflight_output" != *"Serving Proof Explorer"* && ! -e "$OPEN_CAPTURE" ]]; then
    pass "proof open --server neither listens nor launches after preflight failure"
else
    fail "proof open --server preflight guard" "no server or launcher after proof-data.js mismatch" "$server_preflight_output"
fi

LEGACY_OPEN_DIR="$TEST_DIR/legacy-renderer-bundle"
cp -R "$TEST_DIR/bundle-a" "$LEGACY_OPEN_DIR"
python3 - "$PROJECT_ROOT" "$LEGACY_OPEN_DIR" <<'PY'
import json
import sys
from pathlib import Path

import hashlib
def proof_id_of(document):
    """Recompute the Bundle identity without importing the product.

    The spec's Testing Decisions keep the CLI subprocess as the only seam these
    suites touch, so the identity is recomputed here rather than imported --
    which also makes this an independent check of the rule rather than a
    comparison of the implementation with itself.
    """
    payload = dict(document)
    payload.pop("proof_id", None)
    payload.pop("transport", None)
    return "sha256:" + hashlib.sha256(
        json.dumps(
            payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    ).hexdigest()


bundle_dir = Path(sys.argv[2])
proof_path = bundle_dir / "proof.json"
bundle = json.loads(proof_path.read_text(encoding="utf-8"))
bundle.pop("explorer")
bundle["proof_id"] = proof_id_of(bundle)
proof_path.write_text(
    json.dumps(bundle, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
    encoding="utf-8",
)
(bundle_dir / "proof-data.js").write_bytes(
    (
        "window.PROOF = "
        + json.dumps(bundle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + ";\n"
    ).encode("utf-8")
)
PY
legacy_verify=$(loop proof verify --json "$LEGACY_OPEN_DIR" 2>&1)
legacy_verify_status=$?
assert_exit "legacy renderer Bundle remains canonically valid" 0 "$legacy_verify_status"
if [[ "$legacy_verify" == *'"status": "valid"'* ]]; then
    pass "legacy renderer Bundle is accepted by normal validation"
else
    fail "legacy renderer validation" "a valid verifier report" "$legacy_verify"
fi
assert_open_rejected_without_launcher \
    "proof open refuses legacy renderer metadata" \
    "$LEGACY_OPEN_DIR" \
    "lacks explorer.assets renderer attestations"

SERVER_LOG="$TEST_DIR/proof-open-server.log"
(
    export PATH="$FAKE_OPEN_BIN:$PATH"
    export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
    loop proof open --server "$TEST_DIR/bundle-a"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
server_url=""
# The server validates the whole Bundle, re-hashing every asset, before it
# announces its port. A fixed 3s window is not enough on a loaded CI runner --
# it left server_url empty and the four --server assertions below failed with an
# empty log. Poll for up to 30s instead, returning as soon as the URL appears,
# and give up early if the server process died.
for _ in $(seq 1 300); do
    server_url=$(sed -nE 's/^Serving Proof Explorer at (http:\/\/127\.0\.0\.1:[0-9]+\/)$/\1/p' "$SERVER_LOG" | head -1)
    [[ -n "$server_url" ]] && break
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
done
if [[ -n "$server_url" ]] && python3 - "$server_url" <<'PY'
import sys
from urllib.request import urlopen

with urlopen(sys.argv[1], timeout=2) as response:
    assert b'proof-data.js' in response.read()
PY
then
    pass "proof open --server serves the Explorer on loopback with an ephemeral port"
else
    fail "proof open --server" "a loopback server that serves index.html" "$(<"$SERVER_LOG")"
fi
if python3 - "$server_url" <<'PY'
import sys
from http.client import HTTPConnection
from urllib.parse import urlsplit

parts = urlsplit(sys.argv[1])
assert parts.hostname == "127.0.0.1"
assert parts.port is not None

def status_for(host):
    connection = HTTPConnection(parts.hostname, parts.port, timeout=2)
    connection.putrequest("GET", "/", skip_host=True)
    connection.putheader("Host", host)
    connection.endheaders()
    response = connection.getresponse()
    response.read()
    connection.close()
    return response.status

assert status_for(f"localhost:{parts.port}") == 200
assert status_for(f"LOCALHOST:{parts.port}") == 200
assert status_for(f"127.0.0.1:{parts.port}") == 200
assert status_for(f"attacker.invalid:{parts.port}") == 400
assert status_for("127.0.0.1:1") == 400
PY
then
    pass "proof open --server accepts only the current loopback Host header"
else
    fail "proof open --server Host guard" "200 for loopback and 400 for hostile Host headers" "$(<"$SERVER_LOG")"
fi

printf 'outside the Bundle\n' > "$TEST_DIR/outside-bundle.txt"
ln -s "$TEST_DIR/outside-bundle.txt" "$TEST_DIR/bundle-a/escaped-hosts"
if python3 - "$server_url/escaped-hosts" <<'PY'
import sys
from urllib.error import HTTPError
from urllib.request import urlopen

try:
    urlopen(sys.argv[1], timeout=2)
except HTTPError as error:
    assert error.code == 404
else:
    raise AssertionError("server followed a symlink outside the Bundle")
PY
then
    pass "proof open --server refuses Bundle symlinks that escape its root"
else
    fail "proof open --server symlink guard" "HTTP 404 for an escaped symlink" "$(<"$SERVER_LOG")"
fi
mv "$TEST_DIR/bundle-a/index.html" "$TEST_DIR/bundle-a/index.safe.html"
ln -s "$TEST_DIR/outside-bundle.txt" "$TEST_DIR/bundle-a/index.html"
if python3 - "$server_url" <<'PY'
import sys
from urllib.error import HTTPError
from urllib.request import urlopen

try:
    urlopen(sys.argv[1], timeout=2)
except HTTPError as error:
    assert error.code == 404
else:
    raise AssertionError("server followed an escaped Bundle index")
PY
then
    pass "proof open --server refuses an escaped Bundle index after startup"
else
    fail "proof open --server index guard" "HTTP 404 for an escaped index.html" "$(<"$SERVER_LOG")"
fi
rm "$TEST_DIR/bundle-a/index.html"
mv "$TEST_DIR/bundle-a/index.safe.html" "$TEST_DIR/bundle-a/index.html"
kill "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
rm "$TEST_DIR/bundle-a/escaped-hosts"

mkdir -p "$TEST_DIR/no-explorer"
missing_open_output=$( (
        export PATH="$FAKE_OPEN_BIN:$PATH"
        export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
        loop proof open "$TEST_DIR/no-explorer"
    ) 2>&1 )
missing_open_status=$?
assert_exit "proof open rejects a directory without the packaged Explorer" 1 "$missing_open_status"
if [[ "$missing_open_output" == *"no packaged Explorer"* ]]; then
    pass "proof open missing Explorer failure is actionable"
else
    fail "proof open missing Explorer error" "an actionable packaged Explorer message" "$missing_open_output"
fi

UNSAFE_INDEX_DIR="$TEST_DIR/unsafe-index"
mkdir -p "$UNSAFE_INDEX_DIR"
ln -s "$TEST_DIR/outside-bundle.txt" "$UNSAFE_INDEX_DIR/index.html"
unsafe_index_output=$( (
        export PATH="$FAKE_OPEN_BIN:$PATH"
        export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
        loop proof open "$UNSAFE_INDEX_DIR"
    ) 2>&1 )
unsafe_index_status=$?
assert_exit "proof open rejects an Explorer index symlink outside the Bundle" 1 "$unsafe_index_status"
if [[ "$unsafe_index_output" == *"must remain inside the Bundle"* ]]; then
    pass "proof open escaped index failure is actionable"
else
    fail "proof open escaped index error" "an actionable Bundle-boundary message" "$unsafe_index_output"
fi

mv "$TEST_DIR/bundle-a/app.js" "$TEST_DIR/bundle-a/app.safe.js"
ln -s "$TEST_DIR/outside-bundle.txt" "$TEST_DIR/bundle-a/app.js"
unsafe_asset_output=$( (
        export PATH="$FAKE_OPEN_BIN:$PATH"
        export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
        loop proof open "$TEST_DIR/bundle-a"
    ) 2>&1 )
unsafe_asset_status=$?
assert_exit "proof open rejects an Explorer asset symlink outside the Bundle" 1 "$unsafe_asset_status"
if [[ "$unsafe_asset_output" == *"paths must remain inside the Bundle"* ]]; then
    pass "proof open rejects escaped non-index assets before launching"
else
    fail "proof open escaped asset error" "an actionable Bundle-boundary message" "$unsafe_asset_output"
fi
rm "$TEST_DIR/bundle-a/app.js"
mv "$TEST_DIR/bundle-a/app.safe.js" "$TEST_DIR/bundle-a/app.js"

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

SUBDIRECTORY="$TEST_PROJECT/nested/export"
mkdir -p "$SUBDIRECTORY"
(
    cd "$SUBDIRECTORY" || exit 1
    loop proof export --run "$RUN_DIR" --out "$TEST_DIR/bundle-subdirectory"
) >/dev/null 2>&1
subdirectory_status=$?
assert_exit "subdirectory --run export succeeds" 0 "$subdirectory_status"
subdirectory_id=$(proof_id "$TEST_DIR/bundle-subdirectory/proof.json")
if [[ "$subdirectory_id" == "$first_id" ]]; then
    pass "subdirectory --run preserves the root export proof_id"
else
    fail "subdirectory --run proof_id" "$first_id" "$subdirectory_id"
fi

(
    cd "$SUBDIRECTORY" || exit 1
    loop proof export --latest --out "$TEST_DIR/bundle-subdirectory-latest"
) >/dev/null 2>&1
subdirectory_latest_status=$?
assert_exit "subdirectory --latest export succeeds" 0 "$subdirectory_latest_status"
subdirectory_latest_id=$(proof_id "$TEST_DIR/bundle-subdirectory-latest/proof.json")
if [[ "$subdirectory_latest_id" == "$first_id" ]]; then
    pass "subdirectory --latest preserves the root export proof_id"
else
    fail "subdirectory --latest proof_id" "$first_id" "$subdirectory_latest_id"
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

PROFILE_BASE_COMMIT=$(git -C "$TEST_PROJECT" rev-parse HEAD)
printf 'public profile metadata fixture\n' >> "$TEST_PROJECT/README.md"
git -C "$TEST_PROJECT" add README.md
profile_subject=$'public profile café control \037 metadata'
git -C "$TEST_PROJECT" -c commit.gpgsign=false commit -q -m "$profile_subject"
git -C "$TEST_PROJECT" config i18n.logOutputEncoding ISO-8859-1
PROFILE_HEAD_COMMIT=$(git -C "$TEST_PROJECT" rev-parse HEAD)

PUBLIC_PROFILE_DIR="$TEST_DIR/public-profile-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$PUBLIC_PROFILE_DIR"
mkdir -p "$PUBLIC_PROFILE_DIR/.loop"
printf 'BITLESSON_PRIVATE_BODY must never leave the source Run.\n' > "$PUBLIC_PROFILE_DIR/.loop/bitlesson.md"
printf '{"transcript":"PRIVATE_TRANSCRIPT_BODY"}\n' > "$PUBLIC_PROFILE_DIR/agent-transcript.jsonl"
printf 'PRIVATE_LOG_BODY\n' > "$PUBLIC_PROFILE_DIR/agent-session.log"
printf 'PRIVATE_METHODOLOGY_BODY\n' > "$PUBLIC_PROFILE_DIR/methodology-analysis-report.md"
printf 'Home path: /Users/public-profile/private\n' > "$PUBLIC_PROFILE_DIR/privacy-note.md"
printf '\nPrivate plan path: /Users/public-profile/plan\n' >> "$PUBLIC_PROFILE_DIR/plan.md"
python3 - "$PUBLIC_PROFILE_DIR/complete-state.md" "$PROFILE_BASE_COMMIT" "$PROFILE_HEAD_COMMIT" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
base, head = sys.argv[2:]
text = path.read_text(encoding="utf-8")
text = re.sub(r"^base_commit: .*$", f"base_commit: {base}", text, flags=re.MULTILINE)
text = re.sub(r"^head_commit: .*$", f"head_commit: {head}", text, flags=re.MULTILINE)
text = re.sub(r"^reviewed_commit: .*$", f"reviewed_commit: {head}", text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY

loop proof export --run "$PUBLIC_PROFILE_DIR" --out "$TEST_DIR/public-profile-bundle" >/dev/null 2>&1
public_profile_status=$?
assert_exit "public-v1 is the default export profile" 0 "$public_profile_status"
loop proof export --run "$PUBLIC_PROFILE_DIR" --profile local-v0 --out "$TEST_DIR/local-profile-bundle" >/dev/null 2>&1
local_profile_status=$?
assert_exit "local-v0 remains available as an explicit full-detail profile" 0 "$local_profile_status"
loop proof export --run "$PUBLIC_PROFILE_DIR" --profile local-v0 --out "$TEST_DIR/reused-profile-bundle" >/dev/null 2>&1
reused_local_status=$?
assert_exit "local-v0 can export to a reusable destination" 0 "$reused_local_status"
loop proof export --run "$PUBLIC_PROFILE_DIR" --profile public-v0 --out "$TEST_DIR/reused-profile-bundle" >/dev/null 2>&1
reused_public_status=$?
assert_exit "public-v0 can replace an existing local Bundle" 0 "$reused_public_status"
if python3 - "$TEST_DIR/reused-profile-bundle" <<'PY'
import json
import sys
from pathlib import Path

bundle_dir = Path(sys.argv[1])
bundle = json.loads((bundle_dir / "proof.json").read_text(encoding="utf-8"))
assert bundle["profile"]["name"] == "public-v0"
for item in bundle["evidence"]:
    if item["status"] == "omitted":
        assert not (bundle_dir / "evidence" / item["path"]).exists()
PY
then
    pass "reused public Bundle removes stale local-only evidence"
else
    fail "reused public Bundle privacy" "no raw file for every omitted evidence item" "stale local evidence remained"
fi
UNRELATED_OUTPUT="$TEST_DIR/unrelated-output"
mkdir -p "$UNRELATED_OUTPUT/evidence"
printf 'keep this unrelated file\n' > "$UNRELATED_OUTPUT/evidence/sentinel.txt"
printf '{"schema_version":"proof-bundle-v0"}\n' > "$UNRELATED_OUTPUT/proof.json"
unrelated_output=$(loop proof export --run "$PUBLIC_PROFILE_DIR" --profile public-v0 --out "$UNRELATED_OUTPUT" 2>&1)
unrelated_status=$?
assert_exit "public export refuses a non-Bundle output directory" 1 "$unrelated_status"
if [[ -f "$UNRELATED_OUTPUT/evidence/sentinel.txt" && "$unrelated_output" == *"empty or an existing Proof Bundle"* ]]; then
    pass "refused output leaves unrelated files untouched"
else
    fail "non-Bundle output safety" "untouched sentinel and actionable error" "output directory was modified or error was unclear"
fi
if python3 - "$PUBLIC_PROFILE_DIR" "$TEST_DIR/public-profile-bundle" "$TEST_DIR/local-profile-bundle" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

run_dir, public_dir, local_dir = map(Path, sys.argv[1:])
public = json.loads((public_dir / "proof.json").read_text(encoding="utf-8"))
local = json.loads((local_dir / "proof.json").read_text(encoding="utf-8"))
expected = {
    "round-0-prompt.md": "profile-redaction",
    "round-0-review-prompt.md": "profile-redaction",
    "round-1-review-prompt.md": "profile-redaction",
    ".loop/bitlesson.md": "profile-redaction",
    "agent-transcript.jsonl": "profile-redaction",
    "agent-session.log": "profile-redaction",
    "methodology-analysis-report.md": "profile-redaction",
    "privacy-note.md": "absolute-path",
    "plan.md": "absolute-path",
}
items = {item["path"]: item for item in public["evidence"]}
for relative, reason in expected.items():
    item = items[relative]
    source = (run_dir / relative).read_bytes()
    assert item["status"] == "omitted"
    assert item["omitted_reason"] == reason
    assert item["sha256"] == hashlib.sha256(source).hexdigest()
    assert item["bytes"] == len(source)
    assert not (public_dir / "evidence" / relative).exists()

omitted = {(item["path"], item["reason"]) for item in public["disclosure"]["omitted"]}
assert omitted == {
    (item["path"], item["omitted_reason"])
    for item in public["evidence"]
    if item["status"] == "omitted"
}
assert any(
    warning["reason"] == "redacted-by-profile"
    and warning["target"] == "privacy-note.md"
    for warning in public["integrity"]["compile_warnings"]
)
assert public["disclosure"]["field_redactions"] == [
    {"field": "commit.author_email", "reason": "Public profile privacy policy."}
]
assert local["disclosure"]["field_redactions"] == []
assert public["run_id"] == local["run_id"]
assert public["proof_id"] != local["proof_id"]
assert public["specification"]["goal"] == ""

public_record, local_record = public["commits"][-1], local["commits"][-1]
assert public_record["sha"] == local_record["sha"]
assert public_record["subject"] == local_record["subject"]
assert public_record["subject"] == "public profile café control \x1f metadata"
assert public_record["authored_at"] == local_record["authored_at"]
assert public_record["author_name"] == local_record["author_name"]
assert "author_email" not in public_record
assert local_record["author_email"] == "proof-test@example.invalid"

for output in (path for path in public_dir.rglob("*") if path.is_file()):
    text = output.read_bytes().decode("utf-8", errors="replace")
    assert "BITLESSON_PRIVATE_BODY" not in text
    assert "PRIVATE_TRANSCRIPT_BODY" not in text
    assert "PRIVATE_LOG_BODY" not in text
    assert "PRIVATE_METHODOLOGY_BODY" not in text
    assert "/Users/public-profile/private" not in text
    assert "/Users/public-profile/plan" not in text
assert (local_dir / "evidence" / ".loop" / "bitlesson.md").exists()
assert (local_dir / "evidence" / "privacy-note.md").read_text(encoding="utf-8").strip().endswith("/Users/public-profile/private")
PY
then
    pass "public exports omit whole files, redact commit email, and disclose every withholding"
else
    fail "public profile privacy boundary" "omitted raw evidence, field redaction, and no leaked body/path" "unexpected public or local bundle"
fi

INJECTION_TARGET="$TEST_DIR/injected-git-log"
GIT_OPTION_INJECTION_DIR="$TEST_DIR/git-option-injection-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$GIT_OPTION_INJECTION_DIR"
python3 - "$GIT_OPTION_INJECTION_DIR/complete-state.md" "$INJECTION_TARGET" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
text = path.read_text(encoding="utf-8")
text = re.sub(
    r"^base_commit: .*$",
    f"base_commit: --output={target}",
    text,
    flags=re.MULTILINE,
)
text = re.sub(r"^head_commit: .*$", "head_commit: HEAD", text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
git_option_output=$(loop proof export --run "$GIT_OPTION_INJECTION_DIR" --profile local-v0 --out "$TEST_DIR/git-option-injection-bundle" 2>&1)
git_option_status=$?
assert_exit "invalid Git revision fields fail before Git can interpret options" 1 "$git_option_status"
if [[ ! -e "$INJECTION_TARGET" && ! -e "${INJECTION_TARGET}..HEAD" ]]; then
    pass "invalid Git revision fields cannot write through git log options"
else
    fail "Git revision option injection" "no output file created from a state value" "$git_option_output"
fi

COMMIT_SECRET_BASE=$(git -C "$TEST_PROJECT" rev-parse HEAD)
commit_secret='api_key=commit_subject_secret_123456789'
printf 'commit secret fixture\n' >> "$TEST_PROJECT/README.md"
git -C "$TEST_PROJECT" add README.md
git -C "$TEST_PROJECT" -c commit.gpgsign=false commit -q -m "$commit_secret"
COMMIT_SECRET_HEAD=$(git -C "$TEST_PROJECT" rev-parse HEAD)
COMMIT_SECRET_DIR="$TEST_DIR/commit-secret-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$COMMIT_SECRET_DIR"
python3 - "$COMMIT_SECRET_DIR/complete-state.md" "$COMMIT_SECRET_BASE" "$COMMIT_SECRET_HEAD" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
base, head = sys.argv[2:]
text = path.read_text(encoding="utf-8")
text = re.sub(r"^base_commit: .*$", f"base_commit: {base}", text, flags=re.MULTILINE)
text = re.sub(r"^head_commit: .*$", f"head_commit: {head}", text, flags=re.MULTILINE)
text = re.sub(r"^reviewed_commit: .*$", f"reviewed_commit: {head}", text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
commit_secret_output=$(loop proof export --run "$COMMIT_SECRET_DIR" --profile public-v0 --out "$TEST_DIR/commit-secret-bundle" 2>&1)
commit_secret_status=$?
assert_exit "public-v0 rejects secrets in derived commit metadata" 3 "$commit_secret_status"
if [[ "$commit_secret_output" == *"commit:${COMMIT_SECRET_HEAD}"* && "$commit_secret_output" == *"token-assignment"* && "$commit_secret_output" != *"$commit_secret"* ]]; then
    pass "commit secret diagnostic does not echo the subject value"
else
    fail "commit secret diagnostic redaction" "commit target and class without secret value" "$commit_secret_output"
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
# A round carries both a summary and a review result; spec section J counts
# each round's summary as required evidence.
cp "$RESOLVED_FINDING_DIR/round-0-summary.md" "$RESOLVED_FINDING_DIR/round-1-summary.md"
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
cp "$MIXED_FINDING_DIR/round-0-summary.md" "$MIXED_FINDING_DIR/round-1-summary.md"
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
assert bundle["specification"]["acceptance_criteria"] == []
assert bundle["verdict"]["per_ac"] == []
assert any(
    warning["reason"] == "redacted-by-profile"
    and warning["target"] == "goal-tracker.md"
    for warning in bundle["integrity"]["compile_warnings"]
)
assert {(item["path"], item["reason"]) for item in bundle["disclosure"]["omitted"]} >= {
    ("goal-tracker.md", "absolute-path")
}
assert "/Users/proof-test/private" not in json.dumps(bundle)
PY
then
    pass "redacted completion evidence cannot leak or produce acceptance criteria"
else
    fail "profile-relative completion evidence" "omitted tracker removes its derived acceptance criteria" "unexpected redacted tracker bundle"
fi

REDACTED_STATE_DIR="$TEST_DIR/redacted-state-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$REDACTED_STATE_DIR"
python3 - "$REDACTED_STATE_DIR/complete-state.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"^drift_status: .*$", "drift_status: replan_required", text, flags=re.MULTILINE)
text = re.sub(r"^mainline_stall_count: .*$", "mainline_stall_count: 2", text, flags=re.MULTILINE)
text = re.sub(
    r"^last_mainline_verdict: .*$",
    "last_mainline_verdict: /Users/proof-test/private",
    text,
    flags=re.MULTILINE,
)
path.write_text(text, encoding="utf-8")
PY
loop proof export --run "$REDACTED_STATE_DIR" --profile public-v0 --out "$TEST_DIR/redacted-state-bundle" >/dev/null 2>&1
redacted_state_status=$?
assert_exit "public-v0 exports when a circuit-breaker state is path-redacted" 0 "$redacted_state_status"
if python3 - "$TEST_DIR/redacted-state-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
state = next(item for item in bundle["evidence"] if item["path"] == "complete-state.md")
assert state["status"] == "omitted"
assert all(event["kind"] != "circuit_breaker" for event in bundle["run"]["events"])
assert "/Users/proof-test/private" not in json.dumps(bundle)
PY
then
    pass "path-redacted state does not leak circuit-breaker fields through the timeline"
else
    fail "path-redacted circuit breaker" "a safe public Bundle without leaked state fields" "unexpected redacted state bundle"
fi

TRUNCATED_STATE_DIR="$TEST_DIR/truncated-state-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$TRUNCATED_STATE_DIR"
python3 - "$TRUNCATED_STATE_DIR/complete-state.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"^drift_status: .*$", "drift_status: replan_required", text, flags=re.MULTILINE)
text = re.sub(r"^mainline_stall_count: .*$", "mainline_stall_count: 2", text, flags=re.MULTILINE)
text = re.sub(
    r"^last_mainline_verdict: .*$",
    "last_mainline_verdict: " + ("untrusted-frontmatter-" + "x" * 1_100_000),
    text,
    flags=re.MULTILINE,
)
path.write_text(text, encoding="utf-8")
PY
loop proof export --run "$TRUNCATED_STATE_DIR" --profile public-v0 --out "$TEST_DIR/truncated-state-bundle" >/dev/null 2>&1
truncated_state_status=$?
assert_exit "public-v0 exports when circuit-breaker state is truncated" 0 "$truncated_state_status"
if python3 - "$TEST_DIR/truncated-state-bundle/proof.json" <<'PY'
import json
import sys

bundle = json.load(open(sys.argv[1], encoding="utf-8"))
state = next(item for item in bundle["evidence"] if item["path"] == "complete-state.md")
assert state["status"] == "truncated"
assert all(event["kind"] != "circuit_breaker" for event in bundle["run"]["events"])
assert "untrusted-frontmatter-" not in json.dumps(bundle)
PY
then
    pass "truncated state does not leak circuit-breaker frontmatter into the Bundle"
else
    fail "truncated circuit breaker" "a safe Bundle without projected truncated state" "unexpected truncated state bundle"
fi

TRUNCATED_TRACKER_DIR="$TEST_DIR/truncated-tracker-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$TRUNCATED_TRACKER_DIR"
python3 - "$TRUNCATED_TRACKER_DIR/goal-tracker.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_bytes(
    path.read_bytes()
    + b"\n| 9 | TRACKER_TRUNCATION_SENTINEL | This tracker-only plan change must not be published. | AC1 |\n"
    + b"x" * 1048577
)
PY
printf '\n> [P1] AC1 has a tracker-gated synthetic regression.\n' >> "$TRUNCATED_TRACKER_DIR/round-0-review-result.md"
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
assert bundle["specification"]["goal"] == (
    "Add a tiny Python greeting module with one independently verifiable behavior."
)
assert bundle["specification"]["acceptance_criteria"] == []
assert bundle["verdict"]["per_ac"] == []
assert bundle["verdict"]["required_set"] == []
assert bundle["verdict"]["deferred"] == []
assert all(
    event["kind"] not in {"plan_evolution", "replan"}
    for event in bundle["run"]["events"]
)
assert bundle["findings"]
assert all(finding["ac_refs"] == [] for finding in bundle["findings"])
assert "TRACKER_TRUNCATION_SENTINEL" not in json.dumps(bundle)
PY
then
    pass "truncated tracker prose and all tracker-derived projections stay out of the Bundle"
else
    fail "truncated tracker projection" "no tracker prose, AC rows, finding links, or plan events" "unexpected truncated tracker bundle"
fi

rm -f "$OPEN_CAPTURE"
incomplete_open_output=$( (
        export PATH="$FAKE_OPEN_BIN:$PATH"
        export LOOP_PROOF_OPEN_CAPTURE="$OPEN_CAPTURE"
        loop proof open "$TEST_DIR/truncated-tracker-bundle"
    ) 2>&1 )
incomplete_open_status=$?
assert_exit "proof open allows an incomplete but renderer-attested Bundle" 0 "$incomplete_open_status"
if [[ -f "$OPEN_CAPTURE" ]]; then
    pass "proof open launches an incomplete Bundle only after renderer preflight"
else
    fail "proof open incomplete Bundle" "a launcher invocation" "$incomplete_open_output"
fi

OVERSIZED_BUNDLE_RUN="$TEST_DIR/oversized-bundle-run"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$OVERSIZED_BUNDLE_RUN"
python3 - "$OVERSIZED_BUNDLE_RUN" <<'PY'
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
limit = 10485760
# Written before the padding is sized so its bytes are inside the budget: the
# assertion below pins the published total exactly. The padding rounds are
# still rounds, and spec section J counts the final round's review result as
# required evidence, so without this the Bundle would be `incomplete` for a
# reason unrelated to the size budget under test.
(run_dir / "round-10-review-result.md").write_text(
    "No P0-P9 findings remain.\n", encoding="utf-8"
)
existing_bytes = sum(path.stat().st_size for path in run_dir.rglob("*") if path.is_file())
remaining_bytes = limit - existing_bytes
assert remaining_bytes > 0
per_file, remainder = divmod(remaining_bytes, 10)
assert per_file + (1 if remainder else 0) <= 1048576
for index in range(1, 11):
    size = per_file + (1 if index <= remainder else 0)
    (run_dir / f"round-{index}-summary.md").write_bytes(b"x" * size)
PY
loop proof export --run "$OVERSIZED_BUNDLE_RUN" --profile local-v0 --out "$TEST_DIR/oversized-bundle" >/dev/null 2>&1
oversized_bundle_status=$?
assert_exit "oversized Bundle exports with a warning" 0 "$oversized_bundle_status"
oversized_bundle_report=$(loop proof verify "$TEST_DIR/oversized-bundle" --json)
oversized_bundle_verify_status=$?
assert_exit "oversized Bundle remains valid" 0 "$oversized_bundle_verify_status"
if python3 - "$TEST_DIR/oversized-bundle" "$oversized_bundle_report" <<'PY'
import hashlib
import json
import re
import sys
from copy import deepcopy
from pathlib import Path

bundle_dir = Path(sys.argv[1])
report = json.loads(sys.argv[2])
bundle = json.loads((bundle_dir / "proof.json").read_text(encoding="utf-8"))
published_evidence_bytes = sum(
    item["bytes"] for item in bundle["evidence"] if item["status"] == "included"
)
assert published_evidence_bytes == 10485760
assert any(
    warning["reason"] == "size-budget-exceeded"
    and warning["target"] == "bundle"
    for warning in bundle["integrity"]["compile_warnings"]
)
assert report["status"] == "valid"
assert any(
    warning["reason"] == "size-budget-exceeded"
    and warning["target"] == "bundle"
    for warning in report["warnings"]
)
warning = next(
    warning
    for warning in bundle["integrity"]["compile_warnings"]
    if warning["reason"] == "size-budget-exceeded"
)
reported_bytes = int(re.search(r"is ([0-9]+) bytes", warning["detail"]).group(1))
candidate = deepcopy(bundle)
candidate["integrity"]["compile_warnings"] = [
    item
    for item in candidate["integrity"]["compile_warnings"]
    if item["reason"] != "size-budget-exceeded"
]
identity = deepcopy(candidate)
identity.pop("proof_id", None)
identity.pop("transport", None)
candidate["proof_id"] = "sha256:" + hashlib.sha256(
    json.dumps(
        identity, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
).hexdigest()
projection = deepcopy(candidate)
projection.pop("transport", None)
manifest_bytes = len(
    (json.dumps(projection, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
)
display_bytes = len(
    (
        "window.PROOF = "
        + json.dumps(projection, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + ";\n"
    ).encode("utf-8")
)
explorer_bytes = sum(
    (bundle_dir / name).stat().st_size
    for name in ("index.html", "app.js", "styles.css")
)
assert reported_bytes == manifest_bytes + display_bytes + published_evidence_bytes + explorer_bytes
PY
then
    pass "size budget counts the Explorer and remains a valid Bundle warning"
else
    fail "size budget warning" "size-budget-exceeded without an integrity downgrade" "$oversized_bundle_report"
fi

UNEXPECTED_DIR="$RUNS_DIR/2026-07-30_01-00-00"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/unexpected-derived" "$UNEXPECTED_DIR"
loop proof export --run "$UNEXPECTED_DIR" --out "$TEST_DIR/unexpected-bundle" >/dev/null 2>&1
unexpected_status=$?
assert_exit "unexpected Run exports" 0 "$unexpected_status"

STOP_DIR="$RUNS_DIR/2026-07-30_01-30-00"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/stop-derived" "$STOP_DIR"
loop proof export --run "$STOP_DIR" --profile local-v0 --out "$TEST_DIR/stop-bundle" >/dev/null 2>&1
stop_status=$?
assert_exit "stopped Run exports with circuit-breaker facts" 0 "$stop_status"

CANCEL_DIR="$RUNS_DIR/2026-07-30_02-00-00"
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/cancel-after-review" "$CANCEL_DIR"
loop proof export --run "$CANCEL_DIR" --out "$TEST_DIR/cancel-bundle" >/dev/null 2>&1
cancel_status=$?
assert_exit "cancel Run exports" 0 "$cancel_status"
if python3 - "$TEST_DIR/unexpected-bundle/proof.json" "$TEST_DIR/stop-bundle/proof.json" "$TEST_DIR/cancel-bundle/proof.json" <<'PY'
import json
import sys

unexpected = json.load(open(sys.argv[1], encoding="utf-8"))
stopped = json.load(open(sys.argv[2], encoding="utf-8"))
cancel = json.load(open(sys.argv[3], encoding="utf-8"))
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
assert stopped["run"]["terminal_state"] == "stop"
circuit_breaker = next(
    event for event in stopped["run"]["events"] if event["kind"] == "circuit_breaker"
)
assert circuit_breaker["drift_status"] == "replan_required"
assert circuit_breaker["stall_count"] == 3
assert circuit_breaker["last_mainline_verdict"] == "stalled"
assert circuit_breaker["evidence_refs"]
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

OMITTED_SECRET_DIR="$TEST_DIR/public-omitted-secret-run"
OMITTED_SECRET_VALUE='AKIAABCDEFGHIJKLMNOP'
cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$OMITTED_SECRET_DIR"
printf '\n%s\n' "$OMITTED_SECRET_VALUE" >> "$OMITTED_SECRET_DIR/round-0-prompt.md"
omitted_secret_output=$(loop proof export --run "$OMITTED_SECRET_DIR" --profile public-v0 --out "$TEST_DIR/public-omitted-secret-bundle" 2>&1)
omitted_secret_status=$?
assert_exit "public-v0 omits a secret in profile-redacted evidence" 0 "$omitted_secret_status"
omitted_secret_verify=$(loop proof verify "$TEST_DIR/public-omitted-secret-bundle" --json 2>&1)
omitted_secret_verify_status=$?
assert_exit "public-v0 Bundle with omitted secret verifies" 0 "$omitted_secret_verify_status"
if python3 - "$TEST_DIR/public-omitted-secret-bundle/proof.json" "$omitted_secret_verify" <<'PY'
import json
import sys
from pathlib import Path

proof_path = Path(sys.argv[1])
report = json.loads(sys.argv[2])
bundle = json.loads(proof_path.read_text(encoding="utf-8"))
prompt = next(item for item in bundle["evidence"] if item["path"] == "round-0-prompt.md")
assert prompt["status"] == "omitted"
assert prompt["omitted_reason"] == "profile-redaction"
assert not (proof_path.parent / "evidence" / "round-0-prompt.md").exists()
assert report["status"] == "valid"
PY
then
    pass "omitted secret bytes never enter a valid public Bundle"
else
    fail "omitted secret public Bundle" "redacted prompt and valid verification" "$omitted_secret_output"
fi

for secret_case in pem-header cloud-credential token-assignment; do
    SECRET_DIR="$TEST_DIR/public-${secret_case}-run"
    cp -R "$PROJECT_ROOT/tests/fixtures/proof/runs/clean-complete" "$SECRET_DIR"
    case "$secret_case" in
        pem-header)
            secret_value='-----BEGIN PRIVATE KEY-----'
            ;;
        cloud-credential)
            secret_value='AKIAABCDEFGHIJKLMNOP'
            ;;
        token-assignment)
            secret_value='OPENAI_API_KEY=totally_fake_public_test_key_1234'
            ;;
    esac
    printf '%s\n' "$secret_value" > "$SECRET_DIR/${secret_case}.txt"
    secret_output=$(loop proof export --run "$SECRET_DIR" --profile public-v0 --out "$TEST_DIR/${secret_case}-bundle" 2>&1)
    secret_status=$?
    assert_exit "public-v0 rejects ${secret_case} evidence" 3 "$secret_status"
    if [[ "$secret_output" == *"${secret_case}.txt"* && "$secret_output" == *"$secret_case"* && "$secret_output" != *"$secret_value"* ]]; then
        pass "${secret_case} diagnostic identifies only file and class"
    else
        fail "${secret_case} diagnostic redaction" "file and match type without secret value" "diagnostic redaction contract failed"
    fi
done

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
