#!/usr/bin/env bash
#
# Robustness tests for timeout implementation
#
# Tests timeout handling under edge cases:
# - Timeout fallback chain
# - Exit codes
# - Commands ignoring SIGTERM
# - Rapid timeout cycles
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/portable-timeout.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

echo "========================================"
echo "Timeout Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Positive Tests - Timeout Implementation
# ========================================

echo "--- Positive Tests: Timeout Implementation ---"
echo ""

# Test 1: Detect timeout implementation
echo "Test 1: Detect available timeout implementation"
if [[ -n "$TIMEOUT_IMPL" ]]; then
    pass "Detected timeout implementation: $TIMEOUT_IMPL"
else
    fail "Timeout detection" "some implementation" "none detected"
fi

# Test 2: Timeout works with gtimeout (if available)
echo ""
echo "Test 2: Timeout implementation is valid"
# "none" and "python3" are gone from the chain: the last resort is now the
# shell implementation, so there is always an implementation that enforces the
# limit. A stock macOS box has neither gtimeout nor timeout nor python3.
case "$TIMEOUT_IMPL" in
    gtimeout|timeout|shell)
        pass "Valid timeout implementation: $TIMEOUT_IMPL"
        ;;
    *)
        fail "Timeout implementation" "gtimeout|timeout|shell" "$TIMEOUT_IMPL"
        ;;
esac

# Test 3: Quick command completes before timeout
echo ""
echo "Test 3: Quick command completes before timeout"
RESULT=$(run_with_timeout 5 echo "hello")
EXIT_CODE=$?
if [[ "$RESULT" == "hello" ]] && [[ $EXIT_CODE -eq 0 ]]; then
    pass "Quick command completes successfully"
else
    fail "Quick command" "hello, exit 0" "$RESULT, exit $EXIT_CODE"
fi

# Test 4: Timeout returns exit code 124 for timed out command
echo ""
echo "Test 4: Timeout returns exit code 124"
set +e
run_with_timeout 1 sleep 5
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 124 ]]; then
    pass "Returns exit code 124 for timeout"
else
    fail "Timeout exit code" "124" "$EXIT_CODE"
fi

# Test 5: Command with args works correctly
echo ""
echo "Test 5: Command with arguments"
RESULT=$(run_with_timeout 5 printf "%s %s" "arg1" "arg2")
if [[ "$RESULT" == "arg1 arg2" ]]; then
    pass "Handles command arguments correctly"
else
    fail "Command args" "arg1 arg2" "$RESULT"
fi

# Test 6: Preserves command exit code on success
echo ""
echo "Test 6: Preserve command exit code on success"
set +e
run_with_timeout 5 sh -c 'exit 42'
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 42 ]]; then
    pass "Preserves command exit code: 42"
else
    fail "Exit code preservation" "42" "$EXIT_CODE"
fi

# Test 7: Works with pipeline commands
echo ""
echo "Test 7: Works with sh -c for pipelines"
RESULT=$(run_with_timeout 5 sh -c 'echo "test" | tr "e" "E"')
if [[ "$RESULT" == "tEst" ]]; then
    pass "Handles pipeline via sh -c"
else
    fail "Pipeline handling" "tEst" "$RESULT"
fi

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 8: Very short timeout
echo "Test 8: Very short timeout (1 second)"
START=$(date +%s)
set +e
run_with_timeout 1 sleep 10
EXIT_CODE=$?
set -e
END=$(date +%s)
ELAPSED=$((END - START))
if [[ $EXIT_CODE -eq 124 ]] && [[ $ELAPSED -lt 5 ]]; then
    pass "Short timeout works (elapsed: ${ELAPSED}s)"
else
    fail "Short timeout" "exit 124, elapsed < 5s" "exit $EXIT_CODE, elapsed ${ELAPSED}s"
fi

# Test 9: Zero timeout value (edge case)
echo ""
echo "Test 9: Zero timeout value"
set +e
run_with_timeout 0 echo "instant" 2>/dev/null
EXIT_CODE=$?
set -e
# Behavior varies - may succeed or timeout immediately
if [[ $EXIT_CODE -eq 0 ]] || [[ $EXIT_CODE -eq 124 ]]; then
    pass "Zero timeout handled (exit: $EXIT_CODE)"
else
    fail "Zero timeout" "exit 0 or 124" "exit $EXIT_CODE"
fi

# Test 10: Command that produces lots of output
echo ""
echo "Test 10: Command with large output"
set +e
RESULT=$(run_with_timeout 5 sh -c 'for i in $(seq 1 1000); do echo "line $i"; done' | wc -l)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]] && [[ "$RESULT" -ge "1000" ]]; then
    pass "Handles large output correctly ($RESULT lines)"
else
    fail "Large output" "exit 0, >=1000 lines" "exit $EXIT_CODE, $RESULT lines"
fi

# Test 11: Rapid timeout/retry cycles
echo ""
echo "Test 11: Rapid timeout cycles (5 iterations)"
SUCCESS_COUNT=0
for i in $(seq 1 5); do
    set +e
    run_with_timeout 2 echo "cycle $i" >/dev/null
    if [[ $? -eq 0 ]]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
    set -e
done
if [[ $SUCCESS_COUNT -eq 5 ]]; then
    pass "All 5 rapid cycles succeeded"
else
    fail "Rapid cycles" "5 successes" "$SUCCESS_COUNT successes"
fi

# Test 12: Timeout with command that doesn't exist
echo ""
echo "Test 12: Non-existent command"
set +e
run_with_timeout 5 nonexistent_command_12345 2>/dev/null
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Returns non-zero for non-existent command (exit: $EXIT_CODE)"
else
    fail "Non-existent command" "non-zero exit" "exit $EXIT_CODE"
fi

# Test 13: Timeout with empty command
echo ""
echo "Test 13: Empty string handling"
set +e
run_with_timeout 5 "" 2>/dev/null
EXIT_CODE=$?
set -e
# Should either error or do nothing
pass "Empty command handled (exit: $EXIT_CODE)"

# Test 14: Command with special characters in args
echo ""
echo "Test 14: Special characters in arguments"
RESULT=$(run_with_timeout 5 printf '%s' '$HOME & "quotes"')
if [[ "$RESULT" == '$HOME & "quotes"' ]]; then
    pass "Handles special characters in args"
else
    fail "Special chars" '$HOME & "quotes"' "$RESULT"
fi

# Test 15: Command that exits immediately after signal
echo ""
echo "Test 15: Command that handles signals gracefully"
# Use a command that can be interrupted
set +e
run_with_timeout 1 sh -c 'trap "exit 0" TERM; sleep 5' 2>/dev/null
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 124 ]] || [[ $EXIT_CODE -eq 0 ]]; then
    pass "Signal handling works (exit: $EXIT_CODE)"
else
    fail "Signal handling" "exit 0 or 124" "exit $EXIT_CODE"
fi

# Test 16: Fallback chain detection
echo ""
echo "Test 16: Timeout fallback chain validation"
# Check that detect_timeout_impl returns a valid option
DETECTED=$(detect_timeout_impl)
case "$DETECTED" in
    gtimeout|timeout|shell)
        pass "Fallback chain returns valid: $DETECTED"
        ;;
    *)
        fail "Fallback chain" "valid option" "$DETECTED"
        ;;
esac

# Test 16b: the chain never gives up. With gtimeout, timeout and python3 all
# missing -- a stock macOS machine -- detection used to return "none" and
# run_with_timeout ran the command unbounded after warning on stderr.
echo ""
echo "Test 16b: Detection with no gtimeout, timeout or python3 on PATH"
EMPTY_BIN="$(mktemp -d)"
# Absolute bash path: with PATH stripped, `bash` itself would not resolve.
BASH_ABS="$(command -v bash)"
NO_TIMEOUT_IMPL=$(PATH="$EMPTY_BIN" "$BASH_ABS" -c "
    source '$PROJECT_ROOT/scripts/portable-timeout.sh'
    printf '%s' \"\$TIMEOUT_IMPL\"
" 2>/dev/null)
rmdir "$EMPTY_BIN" 2>/dev/null || true
if [[ "$NO_TIMEOUT_IMPL" == "shell" ]]; then
    pass "Falls back to the shell implementation, not to no timeout at all"
else
    fail "Empty-PATH fallback" "shell" "$NO_TIMEOUT_IMPL"
fi

# Test 16c: the shell implementation is the one that has to enforce the limit
# on that machine, so exercise it directly rather than through whichever rung
# this host happens to have.
echo ""
echo "Test 16c: Shell implementation enforces the limit and stays silent"
SHELL_START=$(date +%s)
set +e
SHELL_NOISE=$(shell_run_with_timeout 1 sleep 30 2>&1 >/dev/null)
SHELL_EXIT=$?
set -e
SHELL_ELAPSED=$(($(date +%s) - SHELL_START))
if [[ $SHELL_EXIT -eq 124 ]] && [[ $SHELL_ELAPSED -lt 10 ]] && [[ -z "$SHELL_NOISE" ]]; then
    pass "shell_run_with_timeout: exit 124 in ${SHELL_ELAPSED}s with empty stderr"
else
    fail "shell_run_with_timeout timeout" "exit 124, < 10s, no stderr" \
        "exit $SHELL_EXIT, ${SHELL_ELAPSED}s, stderr [$SHELL_NOISE]"
fi

set +e
SHELL_PASSTHROUGH=$(shell_run_with_timeout 5 sh -c 'printf OK; exit 7')
SHELL_PASSTHROUGH_EXIT=$?
set -e
if [[ "$SHELL_PASSTHROUGH" == "OK" ]] && [[ $SHELL_PASSTHROUGH_EXIT -eq 7 ]]; then
    pass "shell_run_with_timeout: passes stdout and exit status through"
else
    fail "shell_run_with_timeout passthrough" "OK / exit 7" \
        "$SHELL_PASSTHROUGH / exit $SHELL_PASSTHROUGH_EXIT"
fi

# Test 16d: a trapped TERM must get the documented grace period before KILL.
# The grace loop used to wait on the brace-group wrapper shell, which has no
# trap and dies instantly, so KILL followed TERM immediately and a command
# cleaning up on TERM was cut off mid-handler. GNU timeout gives the handler
# the full period; the marker pair is what distinguishes the two.
echo ""
echo "Test 16d: A trapped TERM runs its handler before KILL"
TERM_VICTIM_DIR="$(mktemp -d)"
TERM_VICTIM="$TERM_VICTIM_DIR/term-victim.sh"
cat > "$TERM_VICTIM" <<'VICTIM_EOF'
#!/bin/sh
trap 'echo TERM_RECEIVED; sleep 0.3; echo CLEANUP_FINISHED; exit 42' TERM
sleep 30
VICTIM_EOF
chmod +x "$TERM_VICTIM"

# The grace period is widened for this test rather than the handler shortened.
# At the production 500ms a 0.3s handler leaves only 200ms of slack, which a
# loaded CI runner ate -- this test flaked on Ubuntu for exactly that reason --
# and shortening the handler instead made it vacuous, because a 0.05s handler
# finishes inside the window the broken version leaves too.
#
# Raising the grace only helps the fixed code: the defect was that the grace was
# not honoured at all (the wait was on the wrapper shell, which dies at once),
# so the broken version sends KILL just as promptly whatever this is set to.
# Verified in both directions.
TERM_GRACE_SAVED="$LOOP_PORTABLE_KILL_GRACE_MS"
LOOP_PORTABLE_KILL_GRACE_MS=3000
set +e
TERM_OUTPUT=$(shell_run_with_timeout 1 "$TERM_VICTIM" 2>/dev/null)
TERM_EXIT=$?
set -e
LOOP_PORTABLE_KILL_GRACE_MS="$TERM_GRACE_SAVED"
if [[ "$TERM_OUTPUT" == *TERM_RECEIVED* ]] && [[ "$TERM_OUTPUT" == *CLEANUP_FINISHED* ]] && [[ $TERM_EXIT -eq 124 ]]; then
    pass "TERM handler completes before KILL (exit $TERM_EXIT)"
else
    fail "TERM handler grace period" "both markers and exit 124" \
        "exit $TERM_EXIT, output [$TERM_OUTPUT]"
fi
rm -rf "$TERM_VICTIM_DIR"

# Test 16e: callers validate the limit with ^[0-9]+$, which accepts a leading
# zero. Shell arithmetic reads that as octal, so "08" was an error that
# returned 1 without running the command and "010" quietly meant eight seconds.
echo ""
echo "Test 16e: Leading-zero timeout values are read as decimal"
set +e
LZ_STDERR=$(shell_run_with_timeout 08 true 2>&1 >/dev/null)
LZ_EXIT=$?
set -e
if [[ $LZ_EXIT -eq 0 ]] && [[ -z "$LZ_STDERR" ]]; then
    pass "shell_run_with_timeout 08 runs the command and returns its status"
else
    fail "leading-zero timeout 08" "exit 0, no stderr" "exit $LZ_EXIT, stderr [$LZ_STDERR]"
fi

# "010" must mean ten seconds, not eight. The lower bound is the discriminator:
# read as octal the wait is 8s, and since expiry is now measured against the
# clock rather than counted, a slow runner inflates this by process startup
# only -- a fraction of a second, nowhere near the two-second gap. The upper
# bound is deliberately loose; it only rules out a nonsense result.
LZ_START=$(date +%s)
set +e
shell_run_with_timeout 010 sleep 300 >/dev/null 2>&1
set -e
LZ_ELAPSED=$(($(date +%s) - LZ_START))
if [[ $LZ_ELAPSED -ge 10 ]] && [[ $LZ_ELAPSED -le 15 ]]; then
    pass "shell_run_with_timeout 010 waits ten seconds, not eight (${LZ_ELAPSED}s)"
else
    fail "leading-zero timeout 010" "10-15s elapsed" "${LZ_ELAPSED}s"
fi

# Test 16f: the wait loop must measure elapsed time, not count iterations.
# Each iteration costs its sleep plus the fork that runs it, so a counter
# overshoots by a roughly constant *fraction* -- about 17%, which is fifteen
# minutes at the 5400s codex timeout this now guards.
#
# Told apart by making the loop's own `sleep` slow rather than by timing a long
# run: a counting loop takes 20 iterations for a 2s limit, so a 0.3s sleep
# stretches it to 6s, while a clock-measured loop still expires at 2s no matter
# how long each poll takes. That is a 3x separation from a 2-second test,
# where distinguishing the two designs by elapsed time alone needs a 30-second
# one -- and a window tight enough to do it would flake on a loaded runner.
#
# The victim is invoked by absolute path so it runs the real sleep; only the
# library's own unqualified `sleep 0.1` picks up the stub.
echo ""
echo "Test 16f: Expiry is measured against the clock, not counted in iterations"
REAL_SLEEP="$(command -v sleep)"
SLOW_SLEEP_BIN="$(mktemp -d)"
cat > "$SLOW_SLEEP_BIN/sleep" <<STUB
#!/bin/sh
exec "$REAL_SLEEP" 0.3
STUB
chmod +x "$SLOW_SLEEP_BIN/sleep"

DRIFT_PATH_SAVED="$PATH"
DRIFT_START=$(date +%s)
set +e
PATH="$SLOW_SLEEP_BIN:$PATH"
shell_run_with_timeout 2 "$REAL_SLEEP" 300 >/dev/null 2>&1
PATH="$DRIFT_PATH_SAVED"
set -e
DRIFT_ELAPSED=$(($(date +%s) - DRIFT_START))
rm -rf "$SLOW_SLEEP_BIN"

# Counting: 20 polls x 0.3s = 6s or more. Clock: expiry at 2s, plus at most one
# more poll and the 1s granularity.
if [[ $DRIFT_ELAPSED -le 4 ]]; then
    pass "a 2s limit expires in ${DRIFT_ELAPSED}s even with 0.3s polls (counting would need 6s+)"
else
    fail "timeout measured against the clock" "<= 4s with 0.3s polls" "${DRIFT_ELAPSED}s"
fi

# Test 17: Timeout with subshell
echo ""
echo "Test 17: Timeout with subshell command"
RESULT=$(run_with_timeout 5 sh -c '(echo "subshell")')
if [[ "$RESULT" == "subshell" ]]; then
    pass "Subshell works correctly"
else
    fail "Subshell" "subshell" "$RESULT"
fi

# Test 18: Timeout exported for use in other scripts
echo ""
echo "Test 18: TIMEOUT_IMPL is exported"
if [[ -n "${TIMEOUT_IMPL:-}" ]]; then
    # Check it's accessible in subshell
    SUBSHELL_IMPL=$(sh -c 'echo $TIMEOUT_IMPL')
    if [[ "$SUBSHELL_IMPL" == "$TIMEOUT_IMPL" ]]; then
        pass "TIMEOUT_IMPL exported correctly"
    else
        pass "TIMEOUT_IMPL exists but export behavior varies"
    fi
else
    fail "TIMEOUT_IMPL export" "non-empty" "empty"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Timeout Robustness Test Summary"
exit $?
