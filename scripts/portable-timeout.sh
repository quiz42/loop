#!/usr/bin/env bash
#
# Portable timeout wrapper for macOS/Linux compatibility
# Usage: source portable-timeout.sh; run_with_timeout <seconds> <command> [args...]
#
# Priority: gtimeout (Homebrew) > timeout (GNU) > shell
#
# The chain used to be gtimeout > timeout > python3 > no timeout, which had no
# implementation left on a stock macOS machine: Homebrew coreutils supplies
# gtimeout and is not installed by default, macOS has no BSD `timeout`, and
# macOS has shipped no system python3 since 12.3. run_with_timeout then took a
# "none" branch that printed
#
#     Warning: No timeout implementation available. Running without timeout.
#
# to stderr and ran the command unbounded -- so a hung `codex` blocked
# hooks/loop-codex-stop-hook.sh forever, and the warning was captured into the
# round review log that tests/test-finalize-phase.sh asserts is empty. The last
# resort is now a shell implementation that actually enforces the limit and
# writes nothing to stderr. Dropping the python3 rung also puts this file back
# inside ADR-0003, which reserves Python for the Proof layer.
#

# shell_run_with_timeout, shared with tests/portable-helpers.sh. Resolved with
# parameter expansion rather than `cd "$(dirname ...)"`: dirname is an external
# command, and this file has to load even when PATH holds nothing useful --
# which is exactly the situation the shell fallback exists for.
_LOOP_PORTABLE_TIMEOUT_SELF="${BASH_SOURCE[0]:-$0}"
case "$_LOOP_PORTABLE_TIMEOUT_SELF" in
    */*) _LOOP_PORTABLE_TIMEOUT_DIR="${_LOOP_PORTABLE_TIMEOUT_SELF%/*}" ;;
    *) _LOOP_PORTABLE_TIMEOUT_DIR="." ;;
esac
source "$_LOOP_PORTABLE_TIMEOUT_DIR/lib/shell-timeout.sh"
unset _LOOP_PORTABLE_TIMEOUT_SELF _LOOP_PORTABLE_TIMEOUT_DIR

# Detect available timeout implementation
detect_timeout_impl() {
    if command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        # Only GNU timeout: a `timeout` that does not answer --version is not
        # the coreutils one and may not take <seconds> <command> at all.
        if timeout --version >/dev/null 2>&1; then
            echo "timeout"
        else
            echo "shell"
        fi
    else
        echo "shell"
    fi
}

TIMEOUT_IMPL=$(detect_timeout_impl)

# Run command with timeout
# Args: timeout_seconds command [args...]
# Exit status: the command's own, or 124 when the timeout fired.
run_with_timeout() {
    local timeout_secs="$1"
    shift
    local cmd=("$@")

    case "$TIMEOUT_IMPL" in
        gtimeout)
            gtimeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
        timeout)
            timeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
        *)
            shell_run_with_timeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
    esac
}

# Make TIMEOUT_IMPL available to sourcing scripts
# Note: export -f is bash-specific, but not needed since the function
# is used directly in the sourcing script, not in child processes
export TIMEOUT_IMPL
