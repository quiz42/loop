#!/usr/bin/env bash
#
# Cross-platform portability tests for the test runner and its shared helpers.
#
# Every assertion here corresponds to a concrete way the suite used to break on
# the macOS system toolchain (BSD userland + Bash 3.2) while passing on Linux:
#
# - `date +%s%N` / `+%s%3N` emit a literal "N" on BSD date, so every elapsed-time
#   calculation raised an arithmetic error.
# - `wc -l` pads its output on BSD, so its result could not be string-compared.
# - BSD sed rejects nested brace blocks and ignores the GNU BRE extensions
#   \+, \? and \| -- silently producing wrong output rather than failing.
# - `grep -P` does not exist in BSD grep, so guards written with it reported
#   "clean" for any input.
# - macOS mktemp -d returns a /var/folders path that is a symlink to
#   /private/var/folders, so temp paths did not match canonicalized hook output.
# - Bash 3.2 has no associative arrays, and run-all-tests.sh used to abort on
#   them and still exit 0 -- a green CI job that ran nothing.
#
# Static guards cover tests/ only. Equivalent defects in scripts/ and hooks/ are
# tracked separately so that this suite stays green while they are fixed.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPT_DIR/run-all-tests.sh"

# shellcheck source=tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Runner Portability Tests"
echo "========================================"
echo ""

# ========================================
# Timestamps
# ========================================

echo "Section 1: Millisecond timestamps"

TS_ONE=$(portable_epoch_ms)
case "$TS_ONE" in
    '' | *[!0-9]*)
        fail "portable_epoch_ms returns digits only" "digits" "$TS_ONE"
        ;;
    *)
        pass "portable_epoch_ms returns digits only"
        ;;
esac

# 1e12 ms is 2001-09-09; anything smaller means the value is not a real
# millisecond epoch (for instance whole seconds mistaken for milliseconds).
if [[ "${#TS_ONE}" -ge 13 ]]; then
    pass "portable_epoch_ms magnitude is a millisecond epoch (${#TS_ONE} digits)"
else
    fail "portable_epoch_ms magnitude" ">= 13 digits" "$TS_ONE"
fi

sleep 0.2
TS_TWO=$(portable_epoch_ms)
if [[ "$TS_TWO" -ge "$TS_ONE" ]]; then
    pass "portable_epoch_ms is non-decreasing"
else
    fail "portable_epoch_ms is non-decreasing" "$TS_TWO >= $TS_ONE" "went backwards"
fi

ELAPSED=$((TS_TWO - TS_ONE))
if [[ "$ELAPSED" -ge 100 ]] && [[ "$ELAPSED" -lt 10000 ]]; then
    pass "portable_epoch_ms advances across a 0.2s sleep (${ELAPSED}ms)"
else
    fail "portable_epoch_ms advances across a 0.2s sleep" "100..10000 ms" "${ELAPSED}ms"
fi

if [[ "$(portable_format_ms 1543)" == "1.5s" ]]; then
    pass "portable_format_ms formats 1543 as 1.5s"
else
    fail "portable_format_ms formats 1543" "1.5s" "$(portable_format_ms 1543)"
fi

if [[ "$(portable_format_ms 0)" == "0.0s" ]]; then
    pass "portable_format_ms formats 0 as 0.0s"
else
    fail "portable_format_ms formats 0" "0.0s" "$(portable_format_ms 0)"
fi

# A suite killed before writing its timing file leaves garbage behind; the
# runner must still print a summary rather than die on an arithmetic error.
if [[ "$(portable_format_ms '1785842782N')" == "0.0s" ]]; then
    pass "portable_format_ms treats non-numeric input as zero"
else
    fail "portable_format_ms non-numeric input" "0.0s" "$(portable_format_ms '1785842782N')"
fi

# ========================================
# Text processing
# ========================================

echo ""
echo "Section 2: Text processing"

ESC=$(printf '\033')
COLORED="${ESC}[0;32mPASS${ESC}[0m: something ${ESC}[1;33mYELLOW${ESC}[0m"
STRIPPED=$(printf '%s\n' "$COLORED" | portable_strip_ansi)
if [[ "$STRIPPED" == "PASS: something YELLOW" ]]; then
    pass "portable_strip_ansi removes SGR sequences and keeps the text"
else
    fail "portable_strip_ansi" "PASS: something YELLOW" "$STRIPPED"
fi

printf 'one\ntwo\nthree\n' > "$TEST_DIR/three-lines.txt"

LINES=$(portable_count_lines "$TEST_DIR/three-lines.txt")
if [[ "$LINES" == "3" ]]; then
    pass "portable_count_lines is string-comparable (no BSD wc padding)"
else
    fail "portable_count_lines" "3" "[$LINES]"
fi

STDIN_LINES=$(printf 'a\nb\n' | portable_count_lines)
if [[ "$STDIN_LINES" == "2" ]]; then
    pass "portable_count_lines reads stdin"
else
    fail "portable_count_lines stdin" "2" "[$STDIN_LINES]"
fi

BYTES=$(portable_count_bytes "$TEST_DIR/three-lines.txt")
if [[ "$BYTES" == "14" ]]; then
    pass "portable_count_bytes is string-comparable"
else
    fail "portable_count_bytes" "14" "[$BYTES]"
fi

if [[ "$(portable_to_lower 'MiXeD Case 123')" == "mixed case 123" ]]; then
    pass "portable_to_lower lowercases without \${var,,}"
else
    fail "portable_to_lower" "mixed case 123" "$(portable_to_lower 'MiXeD Case 123')"
fi

# ========================================
# Frontmatter extraction
# ========================================

echo ""
echo "Section 3: Frontmatter extraction"

FM_FIXTURE="$TEST_DIR/frontmatter.md"
{
    echo "---"
    echo "name: draft-relevance-checker"
    echo "description:   Spaced value here"
    echo "model: haiku"
    echo "---"
    echo ""
    echo "description: decoy in the body"
} > "$FM_FIXTURE"

if [[ "$(portable_frontmatter_value "$FM_FIXTURE" "description")" == "Spaced value here" ]]; then
    pass "portable_frontmatter_value strips leading whitespace from the value"
else
    fail "portable_frontmatter_value description" "Spaced value here" \
        "$(portable_frontmatter_value "$FM_FIXTURE" "description")"
fi

if [[ "$(portable_frontmatter_value "$FM_FIXTURE" "name")" == "draft-relevance-checker" ]]; then
    pass "portable_frontmatter_value reads the first key in the block"
else
    fail "portable_frontmatter_value name" "draft-relevance-checker" \
        "$(portable_frontmatter_value "$FM_FIXTURE" "name")"
fi

if [[ -z "$(portable_frontmatter_value "$FM_FIXTURE" "absent")" ]]; then
    pass "portable_frontmatter_value prints nothing for a missing key"
else
    fail "portable_frontmatter_value missing key" "(empty)" \
        "$(portable_frontmatter_value "$FM_FIXTURE" "absent")"
fi

# The body decoy must not win: the value has to come from inside the fences.
BODY_ONLY="$TEST_DIR/body-only.md"
printf 'description: only in the body\n' > "$BODY_ONLY"
if [[ -z "$(portable_frontmatter_value "$BODY_ONLY" "description")" ]]; then
    pass "portable_frontmatter_value ignores keys outside the frontmatter block"
else
    fail "portable_frontmatter_value body key" "(empty)" \
        "$(portable_frontmatter_value "$BODY_ONLY" "description")"
fi

if [[ -z "$(portable_frontmatter_value "$TEST_DIR/does-not-exist.md" "description")" ]]; then
    pass "portable_frontmatter_value tolerates a missing file"
else
    fail "portable_frontmatter_value missing file" "(empty)" "output produced"
fi

# ========================================
# CJK and emoji detection
# ========================================

echo ""
echo "Section 4: CJK and emoji detection"

if command -v python3 >/dev/null 2>&1; then
    CLEAN_FIXTURE="$TEST_DIR/clean.md"
    printf 'Plain English content only.\n' > "$CLEAN_FIXTURE"

    CJK_FIXTURE="$TEST_DIR/cjk.md"
    EMOJI_FIXTURE="$TEST_DIR/emoji.md"
    python3 - "$CJK_FIXTURE" "$EMOJI_FIXTURE" <<'PY'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("prefix " + chr(0x4E2D) + chr(0x6587) + " suffix\n")

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write("prefix " + chr(0x1F600) + " suffix\n")
PY

    SCAN_STATUS=0
    portable_contains_cjk_or_emoji "$CLEAN_FIXTURE" || SCAN_STATUS=$?
    if [[ "$SCAN_STATUS" -eq 1 ]]; then
        pass "portable_contains_cjk_or_emoji reports clean English content"
    else
        fail "portable_contains_cjk_or_emoji clean" "status 1" "status $SCAN_STATUS"
    fi

    SCAN_STATUS=0
    portable_contains_cjk_or_emoji "$CJK_FIXTURE" || SCAN_STATUS=$?
    if [[ "$SCAN_STATUS" -eq 0 ]]; then
        pass "portable_contains_cjk_or_emoji detects CJK ideographs"
    else
        fail "portable_contains_cjk_or_emoji CJK" "status 0" "status $SCAN_STATUS"
    fi

    SCAN_STATUS=0
    portable_contains_cjk_or_emoji "$EMOJI_FIXTURE" || SCAN_STATUS=$?
    if [[ "$SCAN_STATUS" -eq 0 ]]; then
        pass "portable_contains_cjk_or_emoji detects emoji"
    else
        fail "portable_contains_cjk_or_emoji emoji" "status 0" "status $SCAN_STATUS"
    fi
else
    skip "portable_contains_cjk_or_emoji behavior" "python3 not available"
fi

# ========================================
# Temp directories
# ========================================

echo ""
echo "Section 5: Temp directory resolution"

CANDIDATE_DIR=$(portable_mktemp_dir)
RESOLVED_DIR=$(cd "$CANDIDATE_DIR" && pwd -P)
if [[ "$CANDIDATE_DIR" == "$RESOLVED_DIR" ]]; then
    pass "portable_mktemp_dir returns a fully resolved path"
else
    fail "portable_mktemp_dir resolution" "$RESOLVED_DIR" "$CANDIDATE_DIR"
fi
rmdir "$CANDIDATE_DIR" 2>/dev/null || rm -rf "$CANDIDATE_DIR"

# setup_test_dir feeds ~30 suites; if it stops resolving, path comparisons
# against hook output silently start failing on macOS again.
if [[ "$TEST_DIR" == "$(cd "$TEST_DIR" && pwd -P)" ]]; then
    pass "setup_test_dir exports a fully resolved TEST_DIR"
else
    fail "setup_test_dir resolution" "$(cd "$TEST_DIR" && pwd -P)" "$TEST_DIR"
fi

# ========================================
# Signals
# ========================================

echo ""
echo "Section 6: SIGINT disposition"

SIGINT_CHILD="$TEST_DIR/sigint-child.sh"
cat > "$SIGINT_CHILD" <<'CHILD'
#!/usr/bin/env bash
handled=false
_on_int() { handled=true; echo "TRAP_FIRED"; }
trap '_on_int' INT
( sleep 0.1; kill -INT $$ ) &
helper=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.1
    [[ "$handled" == "true" ]] && break
done
kill "$helper" 2>/dev/null || true
wait "$helper" 2>/dev/null || true
[[ "$handled" == "true" ]]
CHILD
chmod +x "$SIGINT_CHILD"

# Run inside an async subshell, which is how run-all-tests.sh launches suites:
# Bash sets SIGINT to SIG_IGN there, and on macOS the child inherits it.
SIGINT_OUT="$TEST_DIR/sigint-out.txt"
( portable_run_with_default_sigint "$SIGINT_CHILD" > "$SIGINT_OUT" 2>&1 ) &
wait

if grep -q "TRAP_FIRED" "$SIGINT_OUT"; then
    pass "portable_run_with_default_sigint lets a child trap SIGINT from an async subshell"
else
    fail "portable_run_with_default_sigint" "TRAP_FIRED in output" "$(cat "$SIGINT_OUT")"
fi

# ========================================
# Runner contract
# ========================================

echo ""
echo "Section 7: Runner contract"

if bash -n "$RUNNER" 2>/dev/null; then
    pass "run-all-tests.sh parses under the current bash"
else
    fail "run-all-tests.sh parses" "bash -n success" "parse error"
fi

CHECK_OUT="$TEST_DIR/check-only.txt"
if LOOP_TEST_RUNNER_CHECK_ONLY=1 "$RUNNER" > "$CHECK_OUT" 2>&1; then
    if grep -q "Interpreter: Bash" "$CHECK_OUT"; then
        pass "run-all-tests.sh check-only mode reports its interpreter"
    else
        fail "check-only mode output" "Interpreter: Bash ..." "$(cat "$CHECK_OUT")"
    fi
else
    fail "check-only mode exit status" "0" "$? -- $(cat "$CHECK_OUT")"
fi

# The regression from the original report: under macOS Bash 3.2 the runner
# aborted on `declare -A` and still exited 0. It must now refuse to run.
SYSTEM_BASH="/bin/bash"
SYSTEM_BASH_MAJOR=""
if [[ -x "$SYSTEM_BASH" ]]; then
    SYSTEM_BASH_MAJOR=$("$SYSTEM_BASH" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "")
fi

if [[ "$SYSTEM_BASH_MAJOR" =~ ^[0-9]+$ ]] && [[ "$SYSTEM_BASH_MAJOR" -lt 4 ]]; then
    OLD_BASH_OUT="$TEST_DIR/old-bash.txt"
    # LOOP_TEST_RUNNER_REEXEC=1 stands in for "no newer bash is reachable",
    # which is the situation a stock macOS machine is in.
    OLD_BASH_STATUS=0
    LOOP_TEST_RUNNER_REEXEC=1 "$SYSTEM_BASH" "$RUNNER" > "$OLD_BASH_OUT" 2>&1 || OLD_BASH_STATUS=$?

    if [[ "$OLD_BASH_STATUS" -ne 0 ]]; then
        pass "run-all-tests.sh exits non-zero under Bash $SYSTEM_BASH_MAJOR (was a silent exit 0)"
    else
        fail "run-all-tests.sh under old bash" "non-zero exit" "exit 0"
    fi

    if grep -q "requires Bash >=" "$OLD_BASH_OUT"; then
        pass "run-all-tests.sh explains the Bash requirement"
    else
        fail "old bash guidance" "requires Bash >= ..." "$(cat "$OLD_BASH_OUT")"
    fi

    HELPER_PROBE=$("$SYSTEM_BASH" -c "set -uo pipefail
        source '$SCRIPT_DIR/portable-helpers.sh'
        printf '%s|%s|%s' \
            \"\$(portable_epoch_ms)\" \
            \"\$(portable_format_ms 2500)\" \
            \"\$(portable_to_lower ABC)\"" 2>&1)
    case "$HELPER_PROBE" in
        [0-9]*'|2.5s|abc')
            pass "portable-helpers.sh works when sourced under Bash $SYSTEM_BASH_MAJOR"
            ;;
        *)
            fail "portable-helpers.sh under Bash $SYSTEM_BASH_MAJOR" \
                "<digits>|2.5s|abc" "$HELPER_PROBE"
            ;;
    esac
else
    skip "old-bash refusal" "no Bash 3 interpreter at $SYSTEM_BASH to test with"
fi

# An aborted run must never report success: the runner used to exit 0 after
# dying before its summary.
SENTINEL_DIR="$TEST_DIR/sentinel/tests"
mkdir -p "$SENTINEL_DIR"
ln -s "$SCRIPT_DIR/portable-helpers.sh" "$SENTINEL_DIR/portable-helpers.sh"
awk '
    { print }
    /^trap runner_exit_trap EXIT$/ && injected == 0 {
        print "exit 0"
        injected = 1
    }
' "$RUNNER" > "$SENTINEL_DIR/run-all-tests.sh"
chmod +x "$SENTINEL_DIR/run-all-tests.sh"

if grep -q '^exit 0$' "$SENTINEL_DIR/run-all-tests.sh"; then
    SENTINEL_OUT="$TEST_DIR/sentinel-out.txt"
    SENTINEL_STATUS=0
    "$SENTINEL_DIR/run-all-tests.sh" > "$SENTINEL_OUT" 2>&1 || SENTINEL_STATUS=$?

    if [[ "$SENTINEL_STATUS" -ne 0 ]]; then
        pass "an abort before the summary exits non-zero"
    else
        fail "abort sentinel exit status" "non-zero" "exit 0"
    fi

    if grep -q "aborted before printing its summary" "$SENTINEL_OUT"; then
        pass "an abort before the summary says so"
    else
        fail "abort sentinel message" "aborted before printing its summary" \
            "$(cat "$SENTINEL_OUT")"
    fi
else
    fail "abort sentinel setup" "early exit injected into the runner copy" "injection failed"
fi

# ========================================
# Static guards
# ========================================

echo ""
echo "Section 8: Static guards over tests/"

if command -v python3 >/dev/null 2>&1; then
    GUARD_OUT="$TEST_DIR/guard-findings.txt"
    GUARD_STATUS=0
    python3 - "$SCRIPT_DIR" > "$GUARD_OUT" 2>&1 <<'PY' || GUARD_STATUS=$?
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
# These two files are where the portable replacements and these rules live, so
# they are the ones allowed to name the non-portable forms in comments, fallback
# branches and assertion messages.
exempt = {"portable-helpers.sh", "test-runner-portability.sh"}

rules = (
    (
        "nested-sed",
        # The outer brace must open an address block ("{ /^key:/{ ... }") so that
        # "{{PLACEHOLDER}}" text handled by sed does not read as a nested block.
        re.compile(r"(?<![\w])sed\b[^|#]*\{\s*/[^{}]*\{"),
        "nested brace block in a sed script; BSD sed rejects it",
    ),
    (
        "gnu-sed-bre",
        re.compile(r"(?<![\w])sed\b[^|#]*\\[+?|]"),
        r"GNU-only BRE escape (\+, \? or \|) in a sed script; BSD sed treats it literally",
    ),
    (
        "raw-epoch-ns",
        re.compile(r"date\s+\+%s%\d*N"),
        "raw date +%s%N; BSD date has no %N. Use portable_epoch_ms",
    ),
    (
        "bash4-case",
        re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)\}"),
        "Bash 4 case-conversion expansion; use portable_to_lower",
    ),
    (
        "grep-pcre",
        # A real option bundle, so that prose mentioning "grep -P)" or
        # "grep -P;" in a message string is not flagged.
        re.compile(r"(?<![\w])grep\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*P[A-Za-z]*\s"),
        "grep -P; BSD grep has no PCRE support",
    ),
)

findings = []
for path in sorted(root.rglob("*.sh")):
    if path.name in exempt:
        continue
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for name, pattern, message in rules:
            if pattern.search(line):
                relative = path.relative_to(root.parent)
                findings.append("%s:%d: %s: %s" % (relative, number, name, message))

for finding in findings:
    print(finding)

sys.exit(1 if findings else 0)
PY

    if [[ "$GUARD_STATUS" -eq 0 ]]; then
        pass "no non-portable shell constructs in tests/"
    else
        fail "non-portable shell constructs in tests/" "no findings" "$(cat "$GUARD_OUT")"
    fi
else
    skip "static portability guards" "python3 not available"
fi

print_test_summary "Runner Portability Test Summary"
