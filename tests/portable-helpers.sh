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

# Report whether a file contains CJK characters or emoji, which the project rules
# forbid in committed content ("No Emoji or CJK char is allowed").
#
# Exit status: 0 found, 1 not found (or no such file).
#
# The naive form is `grep -P '\p{Han}|[\x{1F300}-...]'`, but BSD grep has no PCRE
# support, so on macOS that call failed and -- with stderr swallowed -- reported
# "clean" for any input at all. ADR-0003 rules out a Python scanner, so instead
# match the UTF-8 encodings of the target ranges as raw bytes in the C locale.
# That is POSIX ERE and behaves identically under GNU and BSD grep.
#
# SCOPE, and how it differs from `grep -P '\p{Han}'`:
#
#   * Every Script=Han code point is flagged. Verified exhaustively against
#     `pcre2grep -u '\p{sc:Han}'` over all 1,112,032 encodable code points:
#     zero misses. Earlier hand-picked ranges missed Ext G/H, the CJK radical
#     blocks, and the plane 1 Han ranges, each of which read as "clean".
#
#   * Deliberately wider than Han: kana, Hangul, Bopomofo, CJK punctuation and
#     symbols, CJK strokes, enclosed and compatibility forms, halfwidth and
#     fullwidth forms, Yijing hexagrams, counting rod numerals and the emoji
#     blocks are all flagged too. The rule this guard enforces says "CJK", not
#     "Han", and a Han-only test passes text written purely in kana or Hangul.
#     Everything flagged outside the CJK scripts lies inside one of the blocks
#     listed below or in unassigned space inside them -- checked exhaustively,
#     so there are no surprise matches anywhere in Unicode.
#
#   * Emoji: the whole of plane 1's pictographic space, U+1F000-U+1FFFF, is
#     flagged. Every emoji outside the BMP lives there -- mahjong and playing
#     cards, enclosed alphanumerics, regional indicators, Symbols and Pictographs
#     Extended-A (U+1FAE0 MELTING FACE among them) and Symbols for Legacy
#     Computing -- and nothing there is ordinary text, so the range is taken
#     wholesale rather than block by block. That also makes it future-proof: new
#     emoji blocks are assigned inside it.
#
#     In the BMP the line is drawn at `Emoji_Presentation`, which is the property
#     for "renders as an emoji by default": every such code point is flagged
#     (U+231A WATCH, U+23F0 ALARM CLOCK, U+2B50 WHITE MEDIUM STAR and the rest).
#
#     `\p{Emoji}` is deliberately *not* the line, because it also contains `#`,
#     `*`, the ASCII digits 0-9, U+00A9 COPYRIGHT SIGN, U+00AE REGISTERED SIGN,
#     U+2122 TRADE MARK SIGN, the arrows at U+2194-2199 and U+25AA BLACK SMALL
#     SQUARE. Those render as text unless a selector follows, and banning them
#     would fail on every English document. Instead the *selectors* are flagged:
#     U+FE0F (VS16) and U+20E3 (combining enclosing keycap). That rejects the
#     rendered emoji -- `(c)`+VS16 and `1`+VS16+keycap both match -- while a bare
#     copyright sign or digit stays clean.
#
#   * Deliberately narrower in one respect: PCRE2 10.43+ resolves `\p{Han}` to
#     Script_Extensions, which pulls in ten characters whose own script is
#     Common or Inherited -- U+00B7 MIDDLE DOT, U+02C7 CARON, U+02C9-02CB,
#     U+02D9 DOT ABOVE, U+02EA-02EB, U+0305 COMBINING OVERLINE and U+0323
#     COMBINING DOT BELOW. Those appear in ordinary Latin and phonetic text, so
#     flagging them would reject legitimate English content. They are excluded.
#
# Not covered, and out of scope for a "no CJK" guard on English documents:
# Tangut, Nushu, Khitan, Yi and Lisu are separate scripts, not CJK.
#
# Usage: if portable_contains_cjk_or_emoji "$file"; then ...
portable_contains_cjk_or_emoji() {
    local file="${1:-}"
    [ -n "$file" ] && [ -f "$file" ] || return 1

    # One UTF-8 byte range per line, written with \0nnn octal escapes so this
    # file itself stays pure ASCII. Keep each comment in step with its escape:
    # tests/test-runner-portability.sh carries a fixture per entry.
    local branches=(
        '\0342[\0230-\0236][\0200-\0277]'             # U+2600-U+27BF   misc symbols, dingbats
        '\0342\0214[\0232-\0233]'                     # U+231A-U+231B   watch, hourglass
        '\0342\0217[\0251-\0263]'                     # U+23E9-U+23F3   media controls, clocks
        '\0342\0227[\0275-\0276]'                     # U+25FD-U+25FE   medium small squares
        '\0342\0254[\0233-\0234]'                     # U+2B1B-U+2B1C   large squares
        '\0342\0255\0220'                             # U+2B50          white medium star
        '\0342\0255\0225'                             # U+2B55          heavy large circle
        '\0342\0203\0243'                             # U+20E3          combining enclosing keycap
        '\0357\0270\0217'                             # U+FE0F          VS16, emoji presentation selector
        '\0342[\0272-\0277][\0200-\0277]'             # U+2E80-U+2FFF   CJK radicals, Kangxi, IDC
        '[\0343-\0351][\0200-\0277][\0200-\0277]'     # U+3000-U+9FFF   CJK punct, kana, bopomofo, Ext A, Unified
        '\0341[\0204-\0207][\0200-\0277]'             # U+1100-U+11FF   Hangul Jamo
        '\0352\0245[\0240-\0277]'                     # U+A960-U+A97F   Hangul Jamo Ext-A
        '\0352[\0260-\0277][\0200-\0277]'             # U+AC00-U+AFFF   Hangul syllables
        '[\0353\0354][\0200-\0277][\0200-\0277]'      # U+B000-U+CFFF   Hangul syllables
        '\0355[\0200-\0237][\0200-\0277]'             # U+D000-U+D7FF   Hangul syllables, Jamo Ext-B
        '\0352\0234[\0200-\0237]'                     # U+A700-U+A71F   modifier tone letters
        '\0357[\0244-\0253][\0200-\0277]'             # U+F900-U+FAFF   CJK compatibility ideographs
        '\0357\0270[\0220-\0237]'                     # U+FE10-U+FE1F   vertical forms
        '\0357\0270[\0260-\0277]'                     # U+FE30-U+FE3F   CJK compatibility forms
        '\0357\0271[\0200-\0257]'                     # U+FE40-U+FE6F   CJK compat forms, small form variants
        '\0357[\0274-\0276][\0200-\0277]'             # U+FF00-U+FFBF   halfwidth and fullwidth forms
        '\0357\0277[\0200-\0257]'                     # U+FFC0-U+FFEF   halfwidth and fullwidth forms
        '\0360\0226\0277[\0242-\0243]'                # U+16FE2-U+16FE3 old Chinese hook and iteration marks
        '\0360\0226\0277[\0260-\0261]'                # U+16FF0-U+16FF1 ideographic tone marks
        '\0360\0232\0277[\0260-\0277]'                # U+1AFF0-U+1AFFF kana Ext-B
        '\0360\0233[\0200-\0204][\0200-\0277]'        # U+1B000-U+1B13F kana supplement, kana Ext-A
        '\0360\0233\0205[\0200-\0257]'                # U+1B140-U+1B16F kana Ext-A
        '\0360\0235\0215[\0240-\0277]'                # U+1D360-U+1D37F counting rod numerals
        '\0360\0237[\0200-\0277][\0200-\0277]'        # U+1F000-U+1FFFF plane 1 pictographs: enclosed ideographic supplement, all emoji blocks
        '\0360[\0240-\0277][\0200-\0277][\0200-\0277]' # U+20000-U+3FFFF planes 2-3: Ext B through Ext H
    )

    local joined pattern
    joined=$(printf '%s|' "${branches[@]}")
    pattern=$(printf '%b' "${joined%|}")

    LC_ALL=C grep -qE "$pattern" "$file"
}

# ========================================
# Timeouts
# ========================================

# Run a command with a wall-clock timeout, using only shell builtins.
#
# GNU coreutils `timeout` is not on the macOS runner image and macOS has shipped
# no system python3 since 12.3, so scripts/portable-timeout.sh -- whose chain is
# gtimeout -> timeout -> python3 -> nothing -- either reaches for Python or gives
# up. ADR-0003 keeps the Bash layer off Python, so tests use this instead.
#
# WHAT IS GUARANTEED
#
#   * The helper itself always returns within the limit plus
#     LOOP_PORTABLE_KILL_GRACE_MS, with status 124 on expiry. TERM alone would not
#     achieve this because it can be trapped or ignored, so KILL follows the grace
#     period.
#
#   * Expiry terminates the command, its process group, and every process still
#     descended from it -- both are needed. `set -m` puts the command in its own
#     group so `kill -- -PID` catches processes spawned after expiry was noticed;
#     the descendant walk catches processes that left that group, because a child
#     running its own `set -m` gets a new process group but keeps its parent. Only
#     signalling the group let the inner `sleep` of `bash -c 'set -m; sleep 30 &
#     wait'` survive, and a caller capturing through $( ) then blocked for the
#     descendant's full lifetime -- 31 seconds under a 1 second limit.
#
# WHAT IS NOT GUARANTEED
#
#   * A process that detaches from the tree entirely -- double-forking, or calling
#     setsid -- is beyond reach, because after reparenting there is no link left to
#     follow. If such a process holds the caller's stdout, a command substitution
#     stays open until it exits, whatever this helper returns. GNU timeout has the
#     same limitation; supervising deliberate daemons needs cgroups or job objects,
#     not a shell.
#
# The command inherits the caller's stdin, stdout and stderr unchanged, so output
# interleaving under 2>&1 is real, piped stdin arrives, a closed stderr stays
# closed, and no auxiliary descriptor is reserved. An earlier version routed the
# command's stderr through fd 3 so the subshell's own stderr could be silenced,
# which broke a caller whose stderr was closed and clobbered a caller's fd 3.
#
# Job control makes Bash announce jobs on the owning shell's stderr, which would
# land in a captured stream. Redirecting a single builtin does not help, because
# Bash 3.2 reports a finished job at whichever command boundary it notices, so the
# job is disowned as soon as it starts and its exit status is passed back through a
# small status file instead of `wait`. Only the status goes through that file.
#
# The wait loop runs in the caller rather than in a background watchdog: a
# `( sleep N; kill ... ) &` watchdog inherits the caller's stdout too, which once
# turned a 4-second suite into 112 seconds.
#
# Caveat, shared with GNU timeout: the command runs in a background process group,
# so one that reads from a terminal gets SIGTTIN rather than the terminal. Callers
# here always redirect or pipe stdin.
#
# Exit status: the command's own status, or 124 when the timeout fired, matching
# GNU timeout so callers can tell the two apart.
#
# Usage: portable_run_with_timeout 30 bash script.sh arg
LOOP_PORTABLE_KILL_GRACE_MS=500

portable_run_with_timeout() {
    local seconds="${1:-0}"
    shift

    # A subshell keeps `set -m` local. No fd juggling: the command gets the
    # caller's descriptors as they are.
    (
        set -m

        # The job is removed from the job table immediately, because Bash 3.2
        # emits "[1]+ Done" at whichever command boundary it happens to notice the
        # exit -- somewhere inside the poll loop, not reliably at `wait` -- so
        # redirecting any single builtin does not suppress it. Without a job to
        # wait on, the exit status comes from a status file. Only the status is
        # written there; the command's own output still goes straight to the
        # caller, so stream ordering and stdin are unaffected.
        status_file=$(mktemp) || exit 1
        # The <&0 goes on the group, not on the command inside it: Bash gives a
        # background command /dev/null for stdin unless it is redirected
        # explicitly, and redirecting inside the group would only re-duplicate that
        # /dev/null.
        { "$@"; printf '%s\n' "$?" > "$status_file"; } <&0 &
        command_pid=$!
        disown %1 2>/dev/null || disown "$command_pid" 2>/dev/null || true

        # Poll in tenths of a second. Bash reaps background children as they exit,
        # so kill -0 stops succeeding promptly rather than lingering on a zombie.
        deadline=$((seconds * 10))
        waited=0
        timed_out=0
        while kill -0 "$command_pid" 2>/dev/null; do
            if [ "$waited" -ge "$deadline" ]; then
                timed_out=1
                break
            fi
            sleep 0.1
            waited=$((waited + 1))
        done

        if [ "$timed_out" -eq 1 ]; then
            # Snapshot the tree first: killing a parent reparents its children and
            # loses the chain that identifies them.
            descendants=$(_portable_descendants "$command_pid")
            _portable_terminate_tree "$command_pid" "$descendants"
            rm -f "$status_file"
            exit 124
        fi

        # The wrapper writes the status before it exits, so by the time kill -0
        # fails the file is complete.
        status=$(cat "$status_file" 2>/dev/null)
        rm -f "$status_file"
        case "$status" in
            '' | *[!0-9]*) status=1 ;;
        esac
        exit "$status"
    )
}

# Print every process still descended from a pid, breadth first, space separated.
# Prints nothing when pgrep is unavailable, in which case the caller falls back to
# signalling the process group alone.
_portable_descendants() {
    local root="$1"
    command -v pgrep >/dev/null 2>&1 || return 0

    local queue="$root"
    local found=""
    local current children
    while [ -n "$queue" ]; do
        current="${queue%% *}"
        case "$queue" in
            *' '*) queue="${queue#* }" ;;
            *) queue="" ;;
        esac
        children=$(pgrep -P "$current" 2>/dev/null | tr '\n' ' ')
        if [ -n "$children" ]; then
            found="$found $children"
            queue="$queue $children"
        fi
    done

    printf '%s' "$found"
}

# TERM a command's process group and any listed descendants, then KILL whatever
# survived the grace period.
#
# The negative PID reaches the whole group, which the leader's own children join
# automatically. The explicit list covers processes that changed group -- a child
# running `set -m` gets its own group but is still a descendant -- and is collected
# before anything is signalled, while the parent links still exist.
_portable_terminate_tree() {
    local target="$1"
    local descendants="${2:-}"
    local pid

    kill -TERM -"$target" 2>/dev/null || kill -TERM "$target" 2>/dev/null
    for pid in $descendants; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    local grace=$((LOOP_PORTABLE_KILL_GRACE_MS / 100))
    [ "$grace" -lt 1 ] && grace=1
    local waited=0
    while kill -0 "$target" 2>/dev/null && [ "$waited" -lt "$grace" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    kill -KILL -"$target" 2>/dev/null || kill -KILL "$target" 2>/dev/null
    for pid in $descendants; do
        kill -KILL "$pid" 2>/dev/null || true
    done
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
