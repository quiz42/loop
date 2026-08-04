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
#     `/^---$/,/^---$/{ /^key:/{ s/^key://p; q; } }`, and ignores the GNU BRE
#     extensions \+, \? and \|, silently matching them as literals.
#   - BSD grep has no `-P`, so a PCRE guard reports "clean" for any input.
#   - macOS `mktemp -d` returns a path under /var/folders, a symlink to
#     /private/var/folders. Code that canonicalizes paths sees the second form,
#     so exact path comparisons fail unless the test canonicalizes too.
#
# Per ADR-0003 only the Proof layer may depend on Python: these helpers use shell
# builtins and POSIX tooling exclusively, so every suite stays runnable on its
# declared interpreter with no Python installed. Where that costs precision the
# helper says so rather than reaching for python3 -- see
# LOOP_PORTABLE_MS_RESOLUTION_MS. tests/test-runner-portability.sh enforces this.
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
#   epochrealtime - Bash 5's $EPOCHREALTIME, microsecond resolution
#   date          - GNU date's %N, millisecond resolution
#   seconds       - whole seconds only (Bash < 5 plus BSD date)
#
# Read LOOP_PORTABLE_MS_RESOLUTION_MS for the resolution a caller can rely on.
LOOP_PORTABLE_MS_MODE=""
LOOP_PORTABLE_MS_RESOLUTION_MS=1

_portable_detect_ms_mode() {
    # Bash 5 exposes microsecond wall-clock time with no external command.
    if [ -n "${EPOCHREALTIME:-}" ]; then
        LOOP_PORTABLE_MS_MODE="epochrealtime"
        LOOP_PORTABLE_MS_RESOLUTION_MS=1
        return 0
    fi

    local probe
    probe=$(date +%s%3N 2>/dev/null || echo "")
    case "$probe" in
        '' | *[!0-9]*)
            # BSD date: emits "<epoch>3N". Fall through to whole seconds.
            ;;
        *)
            LOOP_PORTABLE_MS_MODE="date"
            LOOP_PORTABLE_MS_RESOLUTION_MS=1
            return 0
            ;;
    esac

    # Bash 3.2 on macOS. Whole seconds is the honest answer here: per ADR-0003
    # the Bash layer must not depend on Python, and there is no portable
    # sub-second clock in POSIX shell tooling.
    LOOP_PORTABLE_MS_MODE="seconds"
    LOOP_PORTABLE_MS_RESOLUTION_MS=1000
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
        epochrealtime)
            # "<seconds>.<microseconds>", but the separator follows LC_NUMERIC
            # (a comma in some locales), so split on any non-digit.
            local stamp seconds fraction
            stamp="$EPOCHREALTIME"
            seconds="${stamp%%[!0-9]*}"
            fraction="${stamp#*[!0-9]}"
            if [ "$fraction" = "$stamp" ]; then
                fraction="000"
            fi
            # Pad, then keep exactly milliseconds. 10# forces base 10 so a
            # fraction like "070" is not read as octal.
            fraction="${fraction}000"
            echo "$(( seconds * 1000 + 10#${fraction:0:3} ))"
            ;;
        date)
            date +%s%3N
            ;;
        *)
            # Whole-second resolution, still digits only.
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
# Exit status: 0 found, 1 not found (or no such file).
#
# The naive form for this is `grep -P '[\p{Han}]|[\x{1F300}-...]'`, but BSD grep
# has no PCRE support, so on macOS that call failed and -- with stderr swallowed
# -- reported "clean" for any input at all. Instead, match the UTF-8 encodings of
# those ranges as raw bytes in the C locale, which is POSIX ERE and behaves the
# same under GNU and BSD grep. Per ADR-0003 the Bash layer must not reach for
# Python, so a Python scanner is not an option here.
#
# The byte patterns, built with printf octal escapes so this file itself stays
# pure ASCII:
#   \343-\351 x2 continuation  U+3000-U+9FFF  CJK punctuation through Unified
#                                             Ideographs, including Ext A
#   \357 \244-\253 x1          U+F900-U+FAFF  compatibility ideographs
#   \360 \240-\257 x2          U+20000-...    Unified Ideographs Ext B and later
#   \360\237 \214-\247 x1      U+1F300-U+1F9FF  emoji
#   \342 \230-\236 x1          U+2600-U+27BF  misc symbols and dingbats
#
# Usage: if portable_contains_cjk_or_emoji "$file"; then ...
portable_contains_cjk_or_emoji() {
    local file="${1:-}"
    [ -n "$file" ] && [ -f "$file" ] || return 1

    local pattern
    pattern=$(printf '[\343-\351][\200-\277][\200-\277]|\357[\244-\253][\200-\277]|\360[\240-\257][\200-\277][\200-\277]|\360\237[\214-\247][\200-\277]|\342[\230-\236][\200-\277]')

    LC_ALL=C grep -qE "$pattern" "$file"
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
