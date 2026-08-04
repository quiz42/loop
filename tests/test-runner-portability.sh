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
# ADR-0003 requires the Bash layer to stay independent of Python, which the Proof
# layer alone may depend on. The helpers therefore use only shell builtins and
# POSIX tooling, and the guards below assert that: a stub python3 that fails on
# any invocation is put first on PATH, and the shared infrastructure files are
# scanned for python3 references.
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

echo "  clock source: $LOOP_PORTABLE_MS_MODE (resolution ${LOOP_PORTABLE_MS_RESOLUTION_MS}ms)"

# Sleep past the clock's resolution, whatever it is. Bash 3.2 with BSD date has
# no sub-second source that does not pull in Python, so there the resolution is
# a whole second and the assertion has to allow for it.
if [[ "$LOOP_PORTABLE_MS_RESOLUTION_MS" -ge 1000 ]]; then
    SLEEP_FOR=1.2
    MIN_ELAPSED=1000
else
    SLEEP_FOR=0.2
    MIN_ELAPSED=100
fi

sleep "$SLEEP_FOR"
TS_TWO=$(portable_epoch_ms)
if [[ "$TS_TWO" -ge "$TS_ONE" ]]; then
    pass "portable_epoch_ms is non-decreasing"
else
    fail "portable_epoch_ms is non-decreasing" "$TS_TWO >= $TS_ONE" "went backwards"
fi

ELAPSED=$((TS_TWO - TS_ONE))
if [[ "$ELAPSED" -ge "$MIN_ELAPSED" ]] && [[ "$ELAPSED" -lt 10000 ]]; then
    pass "portable_epoch_ms advances across a ${SLEEP_FOR}s sleep (${ELAPSED}ms)"
else
    fail "portable_epoch_ms advances across a ${SLEEP_FOR}s sleep" \
        "${MIN_ELAPSED}..10000 ms" "${ELAPSED}ms"
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

# Fixtures are written with printf octal escapes so this file itself stays pure
# ASCII, and so the check does not depend on Python being present to build them.
write_codepoint_fixture() {
    printf 'prefix %b suffix\n' "$2" > "$TEST_DIR/scan-$1.txt"
}

# Should be flagged: the ranges the original grep -P expression covered.
write_codepoint_fixture han      '\344\270\255'          # U+4E2D CJK unified
write_codepoint_fixture han-exta '\343\221\220'          # U+3450 Ext A
write_codepoint_fixture han-compat '\357\244\200'        # U+F900 compatibility
write_codepoint_fixture han-extb '\360\240\200\200'     # U+20000 Ext B
write_codepoint_fixture emoji    '\360\237\230\200'     # U+1F600 grinning face
write_codepoint_fixture symbol   '\342\230\200'          # U+2600 misc symbol
write_codepoint_fixture dingbat  '\342\234\224'          # U+2714 dingbat

# Should not be flagged: non-ASCII but neither CJK nor emoji, so the scan must
# not degenerate into "any byte above 0x7F".
write_codepoint_fixture latin1   '\303\251'               # U+00E9 e with acute
write_codepoint_fixture emdash   '\342\200\224'          # U+2014 em dash
write_codepoint_fixture cyrillic '\320\226'               # U+0416 Zhe
write_codepoint_fixture ascii    'plain text'

for name in han han-exta han-compat han-extb emoji symbol dingbat; do
    if portable_contains_cjk_or_emoji "$TEST_DIR/scan-$name.txt"; then
        pass "portable_contains_cjk_or_emoji flags $name"
    else
        fail "portable_contains_cjk_or_emoji flags $name" "detected" "not detected"
    fi
done

for name in latin1 emdash cyrillic ascii; do
    if portable_contains_cjk_or_emoji "$TEST_DIR/scan-$name.txt"; then
        fail "portable_contains_cjk_or_emoji leaves $name alone" "not detected" "detected"
    else
        pass "portable_contains_cjk_or_emoji leaves $name alone"
    fi
done

if portable_contains_cjk_or_emoji "$TEST_DIR/does-not-exist.txt"; then
    fail "portable_contains_cjk_or_emoji missing file" "not detected" "detected"
else
    pass "portable_contains_cjk_or_emoji tolerates a missing file"
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
echo "Section 6: SIGINT stays trappable in a suite"

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

# With job control off, Bash sets SIGINT to SIG_IGN for asynchronous commands,
# macOS passes that ignore on across exec, and a signal ignored on entry can
# never be trapped -- so a suite asserting its own SIGINT handler could not
# observe the signal. run-all-tests.sh enables job control to avoid that; this
# reproduces the runner's launch model and checks the child still sees SIGINT.
SIGINT_OUT="$TEST_DIR/sigint-out.txt"
bash -c 'set -m; ( "$1" > "$2" 2>&1 ) & wait' _ "$SIGINT_CHILD" "$SIGINT_OUT"

if grep -q "TRAP_FIRED" "$SIGINT_OUT"; then
    pass "a suite launched with job control can trap SIGINT"
else
    fail "SIGINT trappable under job control" "TRAP_FIRED in output" "$(cat "$SIGINT_OUT")"
fi

# The behavior above only holds because the runner turns job control on, and the
# test would still pass if that were removed, so assert the runner does it.
if awk '/^set -m$/ { found = 1 } /^for suite in "\$\{TEST_SUITES\[@\]\}"; do$/ { exit found ? 0 : 1 }' "$RUNNER"; then
    pass "run-all-tests.sh enables job control before launching suites"
else
    fail "run-all-tests.sh job control" "set -m before the suite launch loop" "not found"
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
# Independence from Python (ADR-0003)
# ========================================

echo ""
echo "Section 8: Bash layer independence from Python"

# A python3 that fails on every invocation, first on PATH. `command -v python3`
# still succeeds, so a helper that probes for Python and then uses it is caught
# here rather than silently working on machines that happen to have it.
NO_PYTHON_BIN="$TEST_DIR/no-python-bin"
mkdir -p "$NO_PYTHON_BIN"
cat > "$NO_PYTHON_BIN/python3" <<'STUB'
#!/bin/sh
echo "PYTHON3_WAS_INVOKED" >&2
exit 127
STUB
chmod +x "$NO_PYTHON_BIN/python3"

HELPER_PROBE=$(PATH="$NO_PYTHON_BIN:$PATH" bash -c "
    set -uo pipefail
    source '$SCRIPT_DIR/portable-helpers.sh'
    stamp=\$(portable_epoch_ms)
    printf '%s|%s|%s|%s|%s' \
        \"\${stamp//[0-9]/d}\" \
        \"\$(portable_format_ms 2500)\" \
        \"\$(portable_to_lower ABC)\" \
        \"\$(portable_count_lines '$TEST_DIR/three-lines.txt')\" \
        \"\$(portable_frontmatter_value '$FM_FIXTURE' model)\"
    if portable_contains_cjk_or_emoji '$TEST_DIR/scan-han.txt'; then
        printf '|han-flagged'
    else
        printf '|han-MISSED'
    fi
    if portable_contains_cjk_or_emoji '$TEST_DIR/scan-ascii.txt'; then
        printf '|ascii-MISFLAGGED'
    else
        printf '|ascii-clean'
    fi
" 2>&1)

if [[ "$HELPER_PROBE" == *"PYTHON3_WAS_INVOKED"* ]]; then
    fail "helpers avoid python3" "no python3 invocation" "$HELPER_PROBE"
else
    pass "helpers never invoke python3"
fi

EXPECTED_PROBE="ddddddddddddd|2.5s|abc|3|haiku|han-flagged|ascii-clean"
if [[ "$HELPER_PROBE" == "$EXPECTED_PROBE" ]]; then
    pass "every helper still works with python3 unusable"
else
    fail "helpers work without python3" "$EXPECTED_PROBE" "$HELPER_PROBE"
fi

# The shared test infrastructure must not name python3 at all. Individual suites
# may (the Proof suites legitimately do); this covers only the files every suite
# inherits.
PYTHON_REFS=""
for infra in portable-helpers.sh test-helpers.sh run-all-tests.sh; do
    if grep -n 'python3' "$SCRIPT_DIR/$infra" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
        PYTHON_REFS="${PYTHON_REFS}${infra} "
    fi
done
if [[ -z "$PYTHON_REFS" ]]; then
    pass "shared test infrastructure contains no python3 calls"
else
    fail "shared test infrastructure is Python-free" "no python3 references" "$PYTHON_REFS"
fi

# ========================================
# Static guards
# ========================================

echo ""
echo "Section 9: Static guards over tests/"

# Implemented in awk, not Python: this suite is the thing that must not quietly
# acquire a Python dependency (ADR-0003).
#
# portable-helpers.sh and this file are exempt because they are where the
# portable replacements and these rules live, so they necessarily name the
# non-portable forms in comments, patterns and assertion messages.
GUARD_OUT="$TEST_DIR/guard-findings.txt"
find "$SCRIPT_DIR" -name '*.sh' -type f -print0 2>/dev/null \
    | xargs -0 awk '
    # Plain `next` rather than the gawk extension `nextfile`, which mawk on
    # Ubuntu and the BSD awk on macOS do not both provide.
    FILENAME ~ /(portable-helpers|test-runner-portability)\.sh$/ { next }

    # Skip comment lines: naming a construct in prose is not using it.
    /^[[:space:]]*#/ { next }

    # BSD sed rejects a nested brace block. The outer brace must open an address
    # block ("{ /^key:/{ ... }") so that sed handling "{{PLACEHOLDER}}" text is
    # not mistaken for one.
    /(^|[^[:alnum:]_])sed[^|#]*\{[[:space:]]*\/[^{}]*\{/ {
        report("nested-sed", "nested brace block in a sed script; BSD sed rejects it")
    }

    # \+, \? and \| inside a BRE are GNU extensions; BSD sed treats them
    # literally and silently produces wrong output.
    /(^|[^[:alnum:]_])sed[^|#]*\\[+?|]/ {
        report("gnu-sed-bre", "GNU-only BRE escape in a sed script; BSD sed takes it literally")
    }

    # BSD date has no %N.
    /date[[:space:]]+\+%s%[0-9]*N/ {
        report("raw-epoch-ns", "raw date +%s%N; use portable_epoch_ms")
    }

    # ${var,,} and ${var^^} need Bash 4.
    /\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)\}/ {
        report("bash4-case", "Bash 4 case-conversion expansion; use portable_to_lower")
    }

    # BSD grep has no PCRE. Require a real option bundle so that prose
    # mentioning "grep -P)" in a message is not flagged.
    /(^|[^[:alnum:]_])grep[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*P[A-Za-z]*[[:space:]]/ {
        report("grep-pcre", "grep -P; BSD grep has no PCRE support")
    }

    function report(rule, message) {
        printf "%s:%d: %s: %s\n", FILENAME, FNR, rule, message
    }
' > "$GUARD_OUT" 2>&1

if [[ ! -s "$GUARD_OUT" ]]; then
    pass "no non-portable shell constructs in tests/"
else
    fail "non-portable shell constructs in tests/" "no findings" "$(cat "$GUARD_OUT")"
fi

print_test_summary "Runner Portability Test Summary"
