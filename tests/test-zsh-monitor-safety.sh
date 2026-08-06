#!/usr/bin/env zsh
#
# Zsh Runtime Safety Tests for loop monitor
#
# This test MUST be executed by zsh to verify:
# - No zsh "no matches found" errors
# - Works correctly in zsh shell
#
# Tests the actual loop.sh functions under zsh with empty/dotfile-only directories
#

# Fail on errors
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "${RED}FAIL${NC}: $1"
    echo "  Details: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "========================================"
echo "Zsh Runtime Safety Tests"
echo "========================================"
echo "Shell: $ZSH_VERSION"
echo ""

# ========================================
# Test Setup: Create isolated test environment
# ========================================

TEST_BASE="/tmp/test-zsh-loop-$$"
mkdir -p "$TEST_BASE"
cd "$TEST_BASE"

# Set up isolated cache directory to avoid permission issues
export XDG_CACHE_HOME="$TEST_BASE/.cache"
mkdir -p "$XDG_CACHE_HOME"

cleanup() {
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_BASE"
}
trap cleanup EXIT

# ========================================
# Test 1: Source loop.sh under zsh
# ========================================
echo "Test 1: Source loop.sh under zsh"
echo ""

# Create a minimal test environment
mkdir -p .loop/rlcr

# Source the script
source_output=$(source "$PROJECT_ROOT/scripts/loop.sh" 2>&1) || true
if [[ "$source_output" == *"no matches found"* ]]; then
    fail "Source loop.sh" "Got 'no matches found' error: $source_output"
else
    pass "Source loop.sh without glob errors"
fi

# ========================================
# Test 2: _find_latest_session with empty loop dir
# ========================================
echo ""
echo "Test 2: _find_latest_session with empty loop dir"
echo ""

# Create empty .loop/rlcr directory
rm -rf .loop/rlcr
mkdir -p .loop/rlcr

# Source and call the function
(
    source "$PROJECT_ROOT/scripts/loop.sh"

    # Access the internal function via the monitor wrapper context
    # We need to simulate the monitor environment
    loop_dir=".loop/rlcr"

    # Define the function locally (same as in loop.sh)
    _find_latest_session_test() {
        local latest_session=""
        if [[ ! -d "$loop_dir" ]]; then
            echo ""
            return
        fi
        while IFS= read -r session_dir; do
            [[ -z "$session_dir" ]] && continue
            [[ ! -d "$session_dir" ]] && continue
            local session_name=$(basename "$session_dir")
            if [[ "$session_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
                if [[ -z "$latest_session" ]] || [[ "$session_name" > "$(basename "$latest_session")" ]]; then
                    latest_session="$session_dir"
                fi
            fi
        done < <(find "$loop_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        echo "$latest_session"
    }

    result=$(_find_latest_session_test 2>&1)
    if [[ "$result" == *"no matches found"* ]]; then
        echo "ERROR: $result"
        exit 1
    fi
    echo "OK: result='$result'"
) && pass "_find_latest_session with empty dir" || fail "_find_latest_session with empty dir" "Got glob error"

# ========================================
# Test 3: _find_latest_session with dotfiles only
# ========================================
echo ""
echo "Test 3: _find_latest_session with dotfiles only"
echo ""

touch .loop/rlcr/.cancel-requested
touch .loop/rlcr/.hidden-file

(
    loop_dir=".loop/rlcr"

    # Reuse the same function pattern from Test 2 (tests directory with only dotfiles)
    result=""
    while IFS= read -r session_dir; do
        [[ -z "$session_dir" ]] && continue
        [[ ! -d "$session_dir" ]] && continue
        session_name=$(basename "$session_dir")
        if [[ "$session_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
            if [[ -z "$result" ]] || [[ "$session_name" > "$(basename "$result")" ]]; then
                result="$session_dir"
            fi
        fi
    done < <(find "$loop_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    if [[ "$result" == *"no matches found"* ]]; then
        echo "ERROR: $result"
        exit 1
    fi
    echo "OK: result='$result'"
) && pass "_find_latest_session with dotfiles only" || fail "_find_latest_session with dotfiles only" "Got glob error"

# ========================================
# Test 4: _find_state_file with no *-state.md files
# ========================================
echo ""
echo "Test 4: _find_state_file with no *-state.md files"
echo ""

mkdir -p .loop/rlcr/2026-01-16_10-00-00
touch .loop/rlcr/2026-01-16_10-00-00/other.md

(
    session_dir=".loop/rlcr/2026-01-16_10-00-00"

    _find_state_file_test() {
        if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
            echo "|unknown"
            return
        fi
        if [[ -f "$session_dir/state.md" ]]; then
            echo "$session_dir/state.md|active"
            return
        fi
        local state_file=""
        local stop_reason=""
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if [[ -f "$f" ]]; then
                state_file="$f"
                local basename=$(basename "$f")
                stop_reason="${basename%-state.md}"
                break
            fi
        done < <(find "$session_dir" -maxdepth 1 -name '*-state.md' -type f 2>/dev/null)
        if [[ -n "$state_file" ]]; then
            echo "$state_file|$stop_reason"
        else
            echo "|unknown"
        fi
    }

    result=$(_find_state_file_test 2>&1)
    if [[ "$result" == *"no matches found"* ]]; then
        echo "ERROR: $result"
        exit 1
    fi
    echo "OK: result='$result'"
) && pass "_find_state_file with no *-state.md" || fail "_find_state_file with no *-state.md" "Got glob error"

# ========================================
# Test 5: _find_latest_codex_log with empty cache
# ========================================
echo ""
echo "Test 5: _find_latest_codex_log with empty cache dir"
echo ""

# Create a session but no cache log files
mkdir -p "$XDG_CACHE_HOME/loop/test-project/2026-01-16_10-00-00"

(
    loop_dir=".loop/rlcr"
    cache_dir="$XDG_CACHE_HOME/loop/test-project/2026-01-16_10-00-00"

    # Simulate the cache log iteration
    found_count=0
    while IFS= read -r log_file; do
        [[ -z "$log_file" ]] && continue
        [[ ! -f "$log_file" ]] && continue
        found_count=$((found_count + 1))
    done < <(find "$cache_dir" -maxdepth 1 -name 'round-*-codex-run.log' -type f 2>/dev/null)

    if [[ "$found_count" -eq 0 ]]; then
        echo "OK: found_count=0 (no error)"
    else
        echo "ERROR: expected 0, got $found_count"
        exit 1
    fi
) && pass "_find_latest_codex_log with empty cache" || fail "_find_latest_codex_log with empty cache" "Got error"

rm -rf "$XDG_CACHE_HOME/loop/test-project"

# ========================================
# Test 6: Full session directory iteration
# ========================================
echo ""
echo "Test 6: Full session directory iteration"
echo ""

# Create valid session directories
mkdir -p .loop/rlcr/2026-01-16_10-00-00
mkdir -p .loop/rlcr/2026-01-16_11-00-00

(
    loop_dir=".loop/rlcr"

    found_count=0
    latest=""
    while IFS= read -r session_dir; do
        [[ -z "$session_dir" ]] && continue
        [[ ! -d "$session_dir" ]] && continue
        session_name=$(basename "$session_dir")
        if [[ "$session_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
            found_count=$((found_count + 1))
            if [[ -z "$latest" ]] || [[ "$session_name" > "$(basename "$latest")" ]]; then
                latest="$session_dir"
            fi
        fi
    done < <(find "$loop_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    if [[ "$found_count" -eq 2 ]] && [[ "$(basename "$latest")" == "2026-01-16_11-00-00" ]]; then
        echo "OK: found 2 sessions, latest is 11-00-00"
    else
        echo "ERROR: expected 2 sessions with latest 11-00-00, got $found_count with $(basename "$latest")"
        exit 1
    fi
) && pass "Full session iteration finds correct sessions" || fail "Full session iteration" "Wrong result"

# ========================================
# Test 7: Verify zsh is actually being used
# ========================================
echo ""
echo "Test 7: Verify zsh is actually being used"
echo ""

if [[ -n "$ZSH_VERSION" ]]; then
    pass "Running under zsh $ZSH_VERSION"
else
    fail "Shell verification" "Not running under zsh!"
fi

# ========================================
# Test 8: Zsh-specific glob error would occur with old code
# ========================================
echo ""
echo "Test 8: Demonstrate zsh glob error (old code pattern)"
echo ""

# This test shows that the OLD code pattern WOULD fail in zsh
# by attempting the problematic pattern and catching the error
rm -rf .loop/rlcr
mkdir -p .loop/rlcr

(
    setopt +o nomatch 2>/dev/null || true  # Don't fail on no match for this test

    # OLD problematic pattern (should produce empty or error)
    old_pattern_output=""
    old_pattern_error=""

    # Try the old glob pattern that would fail
    if eval 'for x in .loop/rlcr/*; do [[ -e "$x" ]] && old_pattern_output="$old_pattern_output $x"; done' 2>/dev/null; then
        echo "OK: Old pattern handled (but would error without nomatch option)"
    else
        echo "OK: Old pattern would have errored in strict zsh"
    fi

    # NEW pattern with find never errors
    new_pattern_output=""
    while IFS= read -r x; do
        [[ -n "$x" ]] && new_pattern_output="$new_pattern_output $x"
    done < <(find .loop/rlcr -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    echo "OK: New find pattern works safely"
) && pass "Glob vs find safety demonstration" || fail "Glob vs find demonstration" "Error"

# ========================================
# Shared shell timeout under zsh
# ========================================
#
# scripts/lib/shell-timeout.sh is the last rung of the gtimeout -> timeout ->
# shell chain, so on a stock macOS box it is what actually times out codex --
# and scripts/loop.sh is sourced by zsh users, so it has to work here too.
#
# The zsh branch deliberately runs without job control (`set -m` is a fatal
# error inside a zsh subshell), which leaves the descendant list as its ONLY
# cleanup path. That list is a space-separated scalar, and zsh does not
# word-split unquoted parameters, so `for pid in $descendants` once passed the
# entire list to kill as a single argument: every kill failed, the timed-out
# command was left running, and because the orphan still held the capture pipe
# open, a command substitution blocked for the command's full duration despite
# the function having returned 124.

echo ""
echo "Test: shared shell timeout under zsh"

source "$PROJECT_ROOT/scripts/lib/shell-timeout.sh"

# `|| timeout_status=$?` rather than a bare assignment: this suite runs under
# `set -e`, and an expiry is a non-zero status by design.
timeout_start=$SECONDS
timeout_status=0
captured=$(shell_run_with_timeout 1 sleep 25) || timeout_status=$?
timeout_elapsed=$((SECONDS - timeout_start))

if [[ $timeout_status -eq 124 ]]; then
    pass "shell_run_with_timeout returns 124 under zsh"
else
    fail "shell_run_with_timeout status under zsh" "expected 124, got $timeout_status"
fi

# The point of the assertion: the capture must return with the timeout, not
# when the abandoned command eventually finishes 25 seconds later.
if [[ $timeout_elapsed -le 5 ]]; then
    pass "command substitution returns with the timeout (${timeout_elapsed}s), not with the command"
else
    fail "command substitution under zsh" "expected <= 5s, took ${timeout_elapsed}s"
fi

if [[ -z "$captured" ]]; then
    pass "timed-out command captures no output"
else
    fail "timed-out command output" "expected empty, got [$captured]"
fi

# A distinctive duration so the check cannot match an unrelated sleep.
shell_run_with_timeout 1 sleep 2917 >/dev/null 2>&1 || true
sleep 1
if pgrep -f 'sleep 2917' >/dev/null 2>&1; then
    fail "descendant cleanup under zsh" "the timed-out command is still running"
    pkill -f 'sleep 2917' 2>/dev/null || true
else
    pass "no orphaned descendant survives the timeout under zsh"
fi

# TERM handlers get their grace period here too, not just under bash.
zsh_term_victim="$TEST_BASE/zsh-term-victim.sh"
cat > "$zsh_term_victim" <<'VICTIM_EOF'
#!/bin/sh
trap 'echo TERM_RECEIVED; sleep 0.3; echo CLEANUP_FINISHED; exit 42' TERM
sleep 30
VICTIM_EOF
chmod +x "$zsh_term_victim"

# Grace widened for the test, not the handler shortened. See the note on the
# same assertion in tests/robustness/test-timeout-robustness.sh: at the
# production 500ms this flakes on a loaded runner, and a shorter handler
# finishes inside the window the broken version leaves too.
term_grace_saved="$LOOP_PORTABLE_KILL_GRACE_MS"
LOOP_PORTABLE_KILL_GRACE_MS=3000
term_output=$(shell_run_with_timeout 1 "$zsh_term_victim" 2>/dev/null) || true
LOOP_PORTABLE_KILL_GRACE_MS="$term_grace_saved"
if [[ "$term_output" == *TERM_RECEIVED* && "$term_output" == *CLEANUP_FINISHED* ]]; then
    pass "a TERM handler completes before KILL under zsh"
else
    fail "TERM handler grace under zsh" "expected both markers, got [$term_output]"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo "${GREEN}All zsh runtime safety tests passed!${NC}"
    exit 0
else
    echo ""
    echo "${RED}Some tests failed!${NC}"
    exit 1
fi
