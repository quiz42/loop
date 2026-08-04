#!/usr/bin/env bash
#
# Portable shell helpers shared by the Loop test suites and the test runner.
#
# Usage: source "$SCRIPT_DIR/portable-helpers.sh"          (from tests/)
# Usage: source "$SCRIPT_DIR/../portable-helpers.sh"       (from tests/robustness/)
#
# Every helper here exists because the naive form behaves differently on the
# GNU userland (Linux CI) and the BSD userland (macOS CI):
#
#   - `date +%s%N` / `date +%s%3N` produce a literal "N" / "3N" on BSD date,
#     which turns every millisecond calculation into an arithmetic error.
#   - `wc -l` pads its output with leading spaces on BSD, so its result cannot
#     be compared as a string.
#   - BSD sed rejects nested brace blocks such as
#     `/^---$/,/^---$/{ /^key:/{ s/^key://p; q; } }`.
#   - macOS `mktemp -d` returns a path under /var/folders, a symlink to
#     /private/var/folders. Code that canonicalizes paths sees the second form,
#     so exact path comparisons fail unless the test canonicalizes too.
#
# This file is sourced, never executed as a test suite, so it is deliberately
# absent from TEST_SUITES in run-all-tests.sh.
#

# Guard against repeated sourcing (suites may source this and test-helpers.sh
# from nested helper functions).
if [ -n "${LOOP_PORTABLE_HELPERS_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
LOOP_PORTABLE_HELPERS_LOADED=1

# ========================================
# Timestamps
# ========================================

# Cached result of the millisecond-timestamp capability probe:
# "date" (GNU date with %N), "python3", or "seconds" (whole seconds only).
LOOP_PORTABLE_MS_MODE=""

_portable_detect_ms_mode() {
    local probe
    probe=$(date +%s%3N 2>/dev/null || echo "")
    case "$probe" in
        '' | *[!0-9]*)
            # BSD date: emits "<epoch>3N". Fall through to the alternatives.
            ;;
        *)
            LOOP_PORTABLE_MS_MODE="date"
            return 0
            ;;
    esac

    if command -v python3 >/dev/null 2>&1; then
        LOOP_PORTABLE_MS_MODE="python3"
        return 0
    fi

    LOOP_PORTABLE_MS_MODE="seconds"
}

# Probe once, at source time, so the cached mode is visible to the command
# substitutions the helper is normally called from. Detecting lazily would
# re-probe inside every subshell.
_portable_detect_ms_mode

# Print the current time in milliseconds since the epoch, digits only.
# Usage: start=$(portable_epoch_ms)
portable_epoch_ms() {
    if [ -z "${LOOP_PORTABLE_MS_MODE:-}" ]; then
        _portable_detect_ms_mode
    fi

    case "$LOOP_PORTABLE_MS_MODE" in
        date)
            date +%s%3N
            ;;
        python3)
            python3 -c 'import time; print(int(time.time() * 1000))'
            ;;
        *)
            # Last resort: whole-second resolution, still digits only.
            echo "$(( $(date +%s) * 1000 ))"
            ;;
    esac
}

# Format a millisecond count as a human-readable duration ("1.5s").
# Non-numeric input is treated as 0 rather than raising an arithmetic error.
# Usage: portable_format_ms 1543
portable_format_ms() {
    local ms="${1:-0}"
    case "$ms" in
        '' | *[!0-9]*) ms=0 ;;
    esac
    local s=$((ms / 1000))
    local frac=$(( (ms % 1000) / 100 ))  # tenths of a second
    echo "${s}.${frac}s"
}

# ========================================
# Text processing
# ========================================

# Strip ANSI SGR color sequences from stdin.
# Usage: stripped=$(printf '%s' "$colored" | portable_strip_ansi)
portable_strip_ansi() {
    local esc
    esc=$(printf '\033')
    sed "s/${esc}\\[[0-9;]*m//g"
}

# Count lines without BSD wc's leading-space padding.
# Usage: portable_count_lines <file>   |   ... | portable_count_lines
portable_count_lines() {
    if [ "$#" -gt 0 ]; then
        wc -l < "$1" | tr -d '[:space:]'
    else
        wc -l | tr -d '[:space:]'
    fi
}

# Count bytes without BSD wc's leading-space padding.
# Usage: portable_count_bytes <file>   |   ... | portable_count_bytes
portable_count_bytes() {
    if [ "$#" -gt 0 ]; then
        wc -c < "$1" | tr -d '[:space:]'
    else
        wc -c | tr -d '[:space:]'
    fi
}

# Lowercase a string. Replaces the Bash 4 only "${var,,}" expansion.
# Usage: lower=$(portable_to_lower "$text")
portable_to_lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# Read a single scalar value out of a file's leading YAML frontmatter block.
# Matches the first "<key>:" line between the first and second "---" fence and
# prints the value with leading whitespace removed. Prints nothing when the key
# is absent, the file has no frontmatter, or the file does not exist.
#
# The key is matched literally, so keys containing regex metacharacters are
# safe. This replaces the nested-brace sed form that BSD sed rejects.
#
# Usage: value=$(portable_frontmatter_value "$file" "description")
portable_frontmatter_value() {
    local file="${1:-}"
    local key="${2:-}"

    [ -n "$file" ] && [ -f "$file" ] || return 0
    [ -n "$key" ] || return 0

    awk -v key="$key" '
        fence == 0 && $0 != "---" { next }
        $0 == "---" {
            fence++
            if (fence >= 2) { exit }
            next
        }
        fence == 1 {
            prefix = key ":"
            if (substr($0, 1, length(prefix)) == prefix) {
                value = substr($0, length(prefix) + 1)
                sub(/^[ \t]+/, "", value)
                print value
                exit
            }
        }
    ' "$file"
}

# Report whether a file contains CJK ideographs or emoji, which the project
# rules forbid in committed content.
#
# Exit status: 0 found, 1 not found, 2 could not scan (no usable engine).
# Callers must treat 2 as a failure rather than as "clean" -- the naive
# `grep -Pq` form silently reported "clean" on macOS, where BSD grep has no -P.
#
# Usage: portable_contains_cjk_or_emoji "$file" ; status=$?
portable_contains_cjk_or_emoji() {
    local file="${1:-}"
    [ -n "$file" ] && [ -f "$file" ] || return 1

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" <<'PY'
import sys
import unicodedata

# Code points only, so this file itself stays free of CJK and emoji characters.
# Mirrors the ranges the original grep -P expression used.
EMOJI_RANGES = ((0x2600, 0x26FF), (0x2700, 0x27BF), (0x1F300, 0x1F9FF))
LOWEST_FLAGGED = 0x2600
CJK_BLOCK_START = 0x2E80


def is_flagged(char):
    point = ord(char)
    for low, high in EMOJI_RANGES:
        if low <= point <= high:
            return True
    if point >= CJK_BLOCK_START and unicodedata.name(char, "").startswith("CJK"):
        return True
    return False


with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    for line in handle:
        for char in line:
            if ord(char) < LOWEST_FLAGGED:
                continue
            if is_flagged(char):
                sys.exit(0)
sys.exit(1)
PY
        return $?
    fi

    if echo "" | grep -Pq '' 2>/dev/null; then
        # GNU grep with PCRE support.
        if grep -Pq '[\p{Han}]|[\x{1F300}-\x{1F9FF}]|[\x{2600}-\x{26FF}]|[\x{2700}-\x{27BF}]' "$file" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    return 2
}

# ========================================
# Signals
# ========================================

# Run a command with SIGINT reset to its default disposition.
#
# Bash sets SIGINT to SIG_IGN for asynchronous commands when job control is off,
# and a signal ignored on entry to a shell cannot be trapped. On macOS that
# disposition is inherited across exec, so a script asserting that its own
# SIGINT trap fires never receives the signal when it was started from a
# background subshell -- which is exactly how run-all-tests.sh launches every
# suite. Linux does not inherit it the same way, which is why such a test can
# pass there and fail on macOS.
#
# Falls back to running the command unchanged when python3 is unavailable, so
# the caller is never worse off than without this helper.
#
# Usage: output=$(portable_run_with_default_sigint ./child.sh 2>&1)
portable_run_with_default_sigint() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
    else
        "$@"
    fi
}

# ========================================
# Temp directories
# ========================================

# Create a temp directory and print its fully resolved path.
#
# macOS mktemp -d returns /var/folders/..., but /var is a symlink to
# /private/var. Hooks and validators canonicalize the paths they inspect, so a
# test comparing an uncanonicalized temp path against hook output never
# matches. On Linux this is a no-op.
#
# Usage: TEST_DIR=$(portable_mktemp_dir)
portable_mktemp_dir() {
    local dir
    dir=$(mktemp -d) || return 1
    ( cd "$dir" && pwd -P )
}

# Print the fully resolved form of an existing directory path.
# Usage: canonical=$(portable_resolve_dir "$dir")
portable_resolve_dir() {
    local dir="${1:-}"
    if [ -d "$dir" ]; then
        ( cd "$dir" && pwd -P )
    else
        printf '%s' "$dir"
    fi
}
