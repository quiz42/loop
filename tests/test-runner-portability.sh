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

# /bin/true does not exist on macOS; resolve it rather than hardcoding a path.
SHELL_TRUE=$(command -v true)

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

# Fixtures are written with printf octal escapes so this file stays pure ASCII
# and so building them needs no Python (ADR-0003).
write_codepoint_fixture() {
    printf 'prefix %b suffix\n' "$2" > "$TEST_DIR/scan-$1.txt"
}

# One fixture per byte range in portable_contains_cjk_or_emoji, so a range that
# silently stops short is caught. Ext G at U+30000 and the plane 1 Han ranges
# were each reported clean by earlier hand-picked ranges.
write_codepoint_fixture symbol          '\342\230\200'          # U+2600  misc symbols
write_codepoint_fixture dingbat         '\342\234\224'          # U+2714  dingbats
write_codepoint_fixture han-radical     '\342\272\200'          # U+2E80  CJK radicals supplement
write_codepoint_fixture han-kangxi      '\342\274\200'          # U+2F00  Kangxi radicals
write_codepoint_fixture cjk-punct       '\343\200\201'          # U+3001  ideographic comma
write_codepoint_fixture hiragana        '\343\201\202'          # U+3042  hiragana
write_codepoint_fixture katakana        '\343\202\242'          # U+30A2  katakana
write_codepoint_fixture bopomofo        '\343\204\205'          # U+3105  bopomofo
write_codepoint_fixture cjk-stroke      '\343\207\200'          # U+31C0  CJK strokes
write_codepoint_fixture enclosed-cjk    '\343\210\240'          # U+3220  enclosed CJK
write_codepoint_fixture han-exta        '\343\221\220'          # U+3450  Ext A
write_codepoint_fixture han             '\344\270\255'          # U+4E2D  Unified
write_codepoint_fixture hangul-jamo     '\341\204\200'          # U+1100  Hangul Jamo
write_codepoint_fixture hangul-jamo-a   '\352\245\240'          # U+A960  Hangul Jamo Ext-A
write_codepoint_fixture hangul-syl      '\352\260\200'          # U+AC00  Hangul syllables
write_codepoint_fixture hangul-syl-b    '\353\200\200'          # U+B000  Hangul syllables
write_codepoint_fixture hangul-syl-c    '\355\200\200'          # U+D000  Hangul syllables
write_codepoint_fixture tone-letter     '\352\234\200'          # U+A700  modifier tone letters
write_codepoint_fixture han-compat      '\357\244\200'          # U+F900  compatibility ideographs
write_codepoint_fixture vertical-form   '\357\270\220'          # U+FE10  vertical forms
write_codepoint_fixture cjk-compat-form '\357\270\260'          # U+FE30  CJK compatibility forms
write_codepoint_fixture sesame-dot      '\357\271\205'          # U+FE45  small form variants
write_codepoint_fixture fullwidth       '\357\274\201'          # U+FF01  fullwidth forms
write_codepoint_fixture halfwidth-stop  '\357\275\241'          # U+FF61  halfwidth ideographic full stop
write_codepoint_fixture fullwidth-cent  '\357\277\240'          # U+FFE0  fullwidth cent sign
write_codepoint_fixture ideo-hook       '\360\226\277\242'      # U+16FE2 old Chinese hook mark
write_codepoint_fixture ideo-tone       '\360\226\277\260'      # U+16FF0 ideographic tone mark
write_codepoint_fixture kana-extb       '\360\232\277\260'      # U+1AFF0 kana Ext-B
write_codepoint_fixture kana-supp       '\360\233\200\200'      # U+1B000 kana supplement
write_codepoint_fixture kana-exta       '\360\233\205\220'      # U+1B150 kana Ext-A
write_codepoint_fixture counting-rod    '\360\235\215\240'      # U+1D360 counting rod numerals
write_codepoint_fixture enclosed-supp   '\360\237\210\200'      # U+1F200 enclosed ideographic supplement
write_codepoint_fixture circled-ideo    '\360\237\211\220'      # U+1F250 circled ideograph
write_codepoint_fixture emoji           '\360\237\230\200'      # U+1F600 emoticons
write_codepoint_fixture emoji-mahjong   '\360\237\200\204'      # U+1F004 mahjong, lowest plane 1 emoji
write_codepoint_fixture emoji-flag      '\360\237\207\246'      # U+1F1E6 regional indicator
write_codepoint_fixture emoji-ext-a     '\360\237\253\240'      # U+1FAE0 melting face, Ext-A
write_codepoint_fixture emoji-legacy    '\360\237\257\260'      # U+1FBF0 symbols for legacy computing
write_codepoint_fixture emoji-watch     '\342\214\232'          # U+231A  BMP Emoji_Presentation
write_codepoint_fixture emoji-clock     '\342\217\260'          # U+23F0  BMP Emoji_Presentation
write_codepoint_fixture emoji-star      '\342\255\220'          # U+2B50  BMP Emoji_Presentation
# Sequences: the base characters stay legal on their own, the selectors do not.
write_codepoint_fixture emoji-vs16      '\302\251\357\270\217'     # U+00A9 U+FE0F rendered copyright emoji
write_codepoint_fixture emoji-keycap    '1\357\270\217\342\203\243'   # U+0031 U+FE0F U+20E3 keycap digit one
write_codepoint_fixture han-extb        '\360\240\200\200'      # U+20000 Ext B
write_codepoint_fixture han-compat-supp '\360\257\240\200'      # U+2F800 compatibility supplement
write_codepoint_fixture han-extg        '\360\260\200\200'      # U+30000 Ext G
write_codepoint_fixture han-exth        '\360\262\216\257'      # U+323AF Ext H, last assigned Han

CJK_FIXTURES="symbol dingbat han-radical han-kangxi cjk-punct hiragana katakana \
bopomofo cjk-stroke enclosed-cjk han-exta han hangul-jamo hangul-jamo-a hangul-syl \
hangul-syl-b hangul-syl-c tone-letter han-compat vertical-form cjk-compat-form \
sesame-dot fullwidth halfwidth-stop fullwidth-cent ideo-hook ideo-tone kana-extb \
kana-supp kana-exta counting-rod enclosed-supp circled-ideo emoji emoji-mahjong \
emoji-flag emoji-ext-a emoji-legacy emoji-watch emoji-clock emoji-star \
emoji-vs16 emoji-keycap han-extb han-compat-supp han-extg han-exth"

# Must stay clean. The first three are the deliberate divergence from PCRE2
# \p{Han}, which resolves to Script_Extensions and so includes characters whose
# own script is Common or Inherited; they occur in ordinary Latin and phonetic
# text. The rest guard against the byte ranges creeping into neighbouring
# scripts, which is easy to do wrong: Latin Extended-D sits directly above the
# modifier tone letters, Arabic presentation forms directly above the small form
# variants, and the Tangut, Nushu and Khitan marks are interleaved with the two
# ideographic marks covered above.
write_codepoint_fixture middle-dot      '\302\267'              # U+00B7  scx Han, script Common
write_codepoint_fixture caron           '\313\207'              # U+02C7  scx Han, script Common
write_codepoint_fixture overline        '\314\205'              # U+0305  scx Han, script Inherited
write_codepoint_fixture latin1          '\303\251'              # U+00E9  e with acute
write_codepoint_fixture emdash          '\342\200\224'          # U+2014  em dash
write_codepoint_fixture cyrillic        '\320\226'              # U+0416  Cyrillic Zhe
write_codepoint_fixture latin-ext-d     '\352\234\240'          # U+A720  Latin Extended-D
write_codepoint_fixture combining-half  '\357\270\240'          # U+FE20  combining half marks
write_codepoint_fixture arabic-pf       '\357\271\260'          # U+FE70  Arabic presentation forms
write_codepoint_fixture tangut-mark     '\360\226\277\240'      # U+16FE0 Tangut iteration mark
write_codepoint_fixture nushu-mark      '\360\226\277\241'      # U+16FE1 Nushu iteration mark
write_codepoint_fixture khitan-filler   '\360\226\277\244'      # U+16FE4 Khitan small script filler
write_codepoint_fixture plane4          '\361\200\200\200'      # U+40000 beyond planes 2-3
# These four are in \p{Emoji} but deliberately not flagged: they are emoji only in
# combination with U+FE0F or U+20E3, and appear in ordinary English text.
write_codepoint_fixture copyright       '\302\251'              # U+00A9  copyright sign
write_codepoint_fixture registered      '\302\256'              # U+00AE  registered sign
write_codepoint_fixture trademark       '\342\204\242'          # U+2122  trade mark sign
write_codepoint_fixture emoji-arrow     '\342\206\224'          # U+2194  left right arrow
write_codepoint_fixture small-square    '\342\226\252'          # U+25AA  Emoji but not Emoji_Presentation
write_codepoint_fixture keycap-base     '1'                     # bare digit, no selector
write_codepoint_fixture ascii           'plain text with 0123456789 # and *'

CLEAN_FIXTURES="middle-dot caron overline latin1 emdash cyrillic latin-ext-d \
combining-half arabic-pf tangut-mark nushu-mark khitan-filler plane4 copyright \
registered trademark emoji-arrow small-square keycap-base ascii"

for name in $CJK_FIXTURES; do
    if portable_contains_cjk_or_emoji "$TEST_DIR/scan-$name.txt"; then
        pass "portable_contains_cjk_or_emoji flags $name"
    else
        fail "portable_contains_cjk_or_emoji flags $name" "detected" "not detected"
    fi
done

for name in $CLEAN_FIXTURES; do
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
# Timeouts
# ========================================

echo ""
echo "Section 5: Shell-native timeout"

# scripts/portable-timeout.sh resolves gtimeout -> timeout -> python3 -> nothing.
# On the macOS runner the first two are absent, so a Bash-only suite using it
# would depend on Python, against ADR-0003. portable_run_with_timeout uses only
# builtins.
TIMEOUT_STATUS=0
portable_run_with_timeout 5 "$SHELL_TRUE" || TIMEOUT_STATUS=$?
if [[ "$TIMEOUT_STATUS" -eq 0 ]]; then
    pass "portable_run_with_timeout passes through a successful status"
else
    fail "portable_run_with_timeout success" "0" "$TIMEOUT_STATUS"
fi

TIMEOUT_STATUS=0
portable_run_with_timeout 5 bash -c 'exit 7' || TIMEOUT_STATUS=$?
if [[ "$TIMEOUT_STATUS" -eq 7 ]]; then
    pass "portable_run_with_timeout passes through a non-zero status"
else
    fail "portable_run_with_timeout non-zero status" "7" "$TIMEOUT_STATUS"
fi

# 124 is GNU timeout's convention, so a caller can tell a timeout from a failure.
TIMEOUT_START=$(portable_epoch_ms)
TIMEOUT_STATUS=0
portable_run_with_timeout 1 sleep 30 || TIMEOUT_STATUS=$?
TIMEOUT_ELAPSED=$(( $(portable_epoch_ms) - TIMEOUT_START ))
if [[ "$TIMEOUT_STATUS" -eq 124 ]]; then
    pass "portable_run_with_timeout reports 124 when the timeout fires"
else
    fail "portable_run_with_timeout timeout status" "124" "$TIMEOUT_STATUS"
fi

# It must actually kill the command rather than wait for it: 30s would blow the
# budget of every suite in the runner.
if [[ "$TIMEOUT_ELAPSED" -lt 15000 ]]; then
    pass "portable_run_with_timeout kills the command (${TIMEOUT_ELAPSED}ms, not 30s)"
else
    fail "portable_run_with_timeout kills the command" "< 15000 ms" "${TIMEOUT_ELAPSED}ms"
fi

# A plain sleep exits on TERM, so it cannot show whether the limit is enforced or
# merely requested. This command ignores TERM, so only KILL ends it. Before the
# grace-then-KILL change it ran to completion and an infinite one never returned.
TIMEOUT_START=$(portable_epoch_ms)
TIMEOUT_STATUS=0
portable_run_with_timeout 1 bash -c 'trap "" TERM; exec sleep 30' || TIMEOUT_STATUS=$?
TIMEOUT_ELAPSED=$(( $(portable_epoch_ms) - TIMEOUT_START ))
if [[ "$TIMEOUT_STATUS" -eq 124 ]] && [[ "$TIMEOUT_ELAPSED" -lt 15000 ]]; then
    pass "portable_run_with_timeout forces a TERM-ignoring command (${TIMEOUT_ELAPSED}ms)"
else
    fail "portable_run_with_timeout forces a TERM-ignoring command" \
        "124 in under 15000 ms" "$TIMEOUT_STATUS in ${TIMEOUT_ELAPSED}ms"
fi

# A descendant that outlives its parent used to inherit the caller's stdout and
# hold the command substitution open until it exited on its own, so the timeout
# was bounded only by the descendant's lifetime. Capturing through $( ) is the
# point of this case.
TIMEOUT_START=$(portable_epoch_ms)
TIMEOUT_STATUS=0
TIMEOUT_OUTPUT=$(portable_run_with_timeout 1 bash -c 'sleep 30 & wait') || TIMEOUT_STATUS=$?
TIMEOUT_ELAPSED=$(( $(portable_epoch_ms) - TIMEOUT_START ))
if [[ "$TIMEOUT_STATUS" -eq 124 ]] && [[ "$TIMEOUT_ELAPSED" -lt 15000 ]]; then
    pass "portable_run_with_timeout is not held open by a surviving descendant (${TIMEOUT_ELAPSED}ms)"
else
    fail "portable_run_with_timeout descendant handling" \
        "124 in under 15000 ms" "$TIMEOUT_STATUS in ${TIMEOUT_ELAPSED}ms"
fi

# Streams must stay separate: one call site captures stderr while discarding
# stdout, so merging them internally would silently change what it asserts.
TIMEOUT_OUT=$(portable_run_with_timeout 5 bash -c 'echo to-stdout; echo to-stderr >&2' 2>/dev/null)
TIMEOUT_ERR=$(portable_run_with_timeout 5 bash -c 'echo to-stdout; echo to-stderr >&2' 2>&1 >/dev/null)
if [[ "$TIMEOUT_OUT" == "to-stdout" && "$TIMEOUT_ERR" == "to-stderr" ]]; then
    pass "portable_run_with_timeout keeps stdout and stderr separate"
else
    fail "portable_run_with_timeout stream separation" \
        "stdout=to-stdout stderr=to-stderr" "stdout=$TIMEOUT_OUT stderr=$TIMEOUT_ERR"
fi

# A nested tree, so the case is a grandchild rather than a direct child. The
# trailing ":" matters: without it Bash exec-optimises the single command away and
# the tree collapses to one level, which is how an earlier version of this test
# passed against an implementation that only signalled direct children.
#
# The process group is what makes this work. Signalling the child plus a snapshot
# of its children left the innermost sleep running.
TIMEOUT_PIDFILE="$TEST_DIR/nested-worker.pid"
rm -f "$TIMEOUT_PIDFILE"
TIMEOUT_START=$(portable_epoch_ms)
TIMEOUT_STATUS=0
portable_run_with_timeout 1 bash -c \
    "bash -c 'sleep 30 & echo \$! > $TIMEOUT_PIDFILE; wait'; :" \
    >/dev/null 2>&1 || TIMEOUT_STATUS=$?
TIMEOUT_ELAPSED=$(( $(portable_epoch_ms) - TIMEOUT_START ))

if [[ "$TIMEOUT_STATUS" -eq 124 ]] && [[ "$TIMEOUT_ELAPSED" -lt 15000 ]]; then
    pass "portable_run_with_timeout bounds a nested process tree (${TIMEOUT_ELAPSED}ms)"
else
    fail "portable_run_with_timeout nested tree" \
        "124 in under 15000 ms" "$TIMEOUT_STATUS in ${TIMEOUT_ELAPSED}ms"
fi

# Give the group signal a moment to land before checking for survivors.
sleep 0.3
TIMEOUT_INNER=$(cat "$TIMEOUT_PIDFILE" 2>/dev/null || true)
if [[ -z "$TIMEOUT_INNER" ]]; then
    fail "portable_run_with_timeout nested cleanup" \
        "the innermost pid to be recorded" "the fixture did not record one"
elif kill -0 "$TIMEOUT_INNER" 2>/dev/null; then
    kill -KILL "$TIMEOUT_INNER" 2>/dev/null || true
    fail "portable_run_with_timeout nested cleanup" \
        "no surviving descendant" "innermost pid $TIMEOUT_INNER outlived the timeout"
else
    pass "portable_run_with_timeout leaves no surviving descendant"
fi

# stdin must reach the command. A background command in a job-control-off shell is
# given /dev/null, so this silently read nothing until fd 0 was passed explicitly.
TIMEOUT_STDIN=$(printf 'stdin-payload' | portable_run_with_timeout 5 cat)
if [[ "$TIMEOUT_STDIN" == "stdin-payload" ]]; then
    pass "portable_run_with_timeout preserves stdin"
else
    fail "portable_run_with_timeout stdin" "stdin-payload" "[$TIMEOUT_STDIN]"
fi

# A caller that combines the streams with 2>&1 must see them in the real order.
# Replaying buffered stdout before buffered stderr turned ABCD into BDAC.
TIMEOUT_DIRECT=$(bash -c 'printf A >&2; printf B; printf C >&2; printf D' 2>&1)
TIMEOUT_MERGED=$(portable_run_with_timeout 5 bash -c 'printf A >&2; printf B; printf C >&2; printf D' 2>&1)
if [[ "$TIMEOUT_MERGED" == "$TIMEOUT_DIRECT" ]]; then
    pass "portable_run_with_timeout preserves combined-stream order ($TIMEOUT_MERGED)"
else
    fail "portable_run_with_timeout combined-stream order" \
        "$TIMEOUT_DIRECT (as direct execution)" "$TIMEOUT_MERGED"
fi

# A descendant that starts its own job control gets a new process group and so
# escapes the group signal, but it is still a child, which is what the descendant
# walk is for. Signalling only the group let this survive and hold the command
# substitution open for the descendant's whole lifetime: 31 seconds under a
# one-second limit.
TIMEOUT_PIDFILE="$TEST_DIR/escaped-worker.pid"
rm -f "$TIMEOUT_PIDFILE"
TIMEOUT_START=$(portable_epoch_ms)
TIMEOUT_STATUS=0
TIMEOUT_OUTPUT=$(portable_run_with_timeout 1 bash -c \
    "set -m; sleep 30 & echo \$! > $TIMEOUT_PIDFILE; wait") || TIMEOUT_STATUS=$?
TIMEOUT_ELAPSED=$(( $(portable_epoch_ms) - TIMEOUT_START ))

if [[ "$TIMEOUT_STATUS" -eq 124 ]] && [[ "$TIMEOUT_ELAPSED" -lt 15000 ]]; then
    pass "portable_run_with_timeout bounds a group-escaping descendant (${TIMEOUT_ELAPSED}ms)"
else
    fail "portable_run_with_timeout group-escaping descendant" \
        "124 in under 15000 ms" "$TIMEOUT_STATUS in ${TIMEOUT_ELAPSED}ms"
fi

sleep 0.3
TIMEOUT_ESCAPEE=$(cat "$TIMEOUT_PIDFILE" 2>/dev/null || true)
if [[ -z "$TIMEOUT_ESCAPEE" ]]; then
    fail "portable_run_with_timeout escapee cleanup" \
        "the escapee pid to be recorded" "the fixture did not record one"
elif kill -0 "$TIMEOUT_ESCAPEE" 2>/dev/null; then
    kill -KILL "$TIMEOUT_ESCAPEE" 2>/dev/null || true
    fail "portable_run_with_timeout escapee cleanup" \
        "no survivor outside the process group" "pid $TIMEOUT_ESCAPEE outlived the timeout"
else
    pass "portable_run_with_timeout kills a descendant that left its process group"
fi

# A transparent stand-in for `timeout` must not reserve caller-owned descriptors.
# Routing the command's stderr through fd 3 broke both of these.
TIMEOUT_STATUS=0
TIMEOUT_CLOSED=$(portable_run_with_timeout 5 sh -c 'printf OK' 2>&-) || TIMEOUT_STATUS=$?
if [[ "$TIMEOUT_STATUS" -eq 0 && "$TIMEOUT_CLOSED" == "OK" ]]; then
    pass "portable_run_with_timeout works with the caller's stderr closed"
else
    fail "portable_run_with_timeout closed stderr" "status 0 and OK" \
        "status $TIMEOUT_STATUS and [$TIMEOUT_CLOSED]"
fi

printf 'fd3-payload' > "$TEST_DIR/fd3.txt"
TIMEOUT_STATUS=0
exec 3<"$TEST_DIR/fd3.txt"
TIMEOUT_FD3=$(portable_run_with_timeout 5 bash -c 'cat <&3') || TIMEOUT_STATUS=$?
exec 3<&-
if [[ "$TIMEOUT_STATUS" -eq 0 && "$TIMEOUT_FD3" == "fd3-payload" ]]; then
    pass "portable_run_with_timeout leaves the caller's fd 3 alone"
else
    fail "portable_run_with_timeout fd 3" "status 0 and fd3-payload" \
        "status $TIMEOUT_STATUS and [$TIMEOUT_FD3]"
fi

# Bash announces a signal-killed job on the owning shell's stderr. That notice
# must not reach the caller, or every timeout would inject noise into a captured
# stream.
TIMEOUT_NOISE=$(portable_run_with_timeout 1 sleep 30 2>&1 >/dev/null)
if [[ -z "$TIMEOUT_NOISE" ]]; then
    pass "portable_run_with_timeout emits no job-control notice on timeout"
else
    fail "portable_run_with_timeout job notice" "(nothing on stderr)" "$TIMEOUT_NOISE"
fi

# ========================================
# Temp directories
# ========================================

echo ""
echo "Section 6: Temp directory resolution"

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
echo "Section 7: SIGINT stays trappable in a suite"

# The child signals itself and checks synchronously: Bash runs a trap as soon as
# the current command finishes, so there is no sleep to lose and no background
# helper whose delivery could arrive after the script exits. An earlier version
# polled for a signal from a background helper and was racy under load.
SIGINT_CHILD="$TEST_DIR/sigint-child.sh"
cat > "$SIGINT_CHILD" <<'CHILD'
#!/usr/bin/env bash
handled=false
trap 'handled=true' INT
kill -INT $$
if [ "$handled" = true ]; then
    echo "TRAP_FIRED"
fi
CHILD
chmod +x "$SIGINT_CHILD"

# Baseline first. A signal ignored on entry to a shell can never be trapped, and
# the ignore is inherited across exec, so if whatever started this suite had
# SIGINT ignored then no descendant can demonstrate the property and the
# assertion below would fail for a reason that has nothing to do with the runner.
# Under run-all-tests.sh the baseline always holds, because the runner enables job
# control precisely so that its suites keep a trappable SIGINT.
SIGINT_BASE="$TEST_DIR/sigint-baseline.txt"
"$SIGINT_CHILD" > "$SIGINT_BASE" 2>&1 || true

if ! grep -q "TRAP_FIRED" "$SIGINT_BASE"; then
    skip "SIGINT trappable under job control" \
        "this suite was started with SIGINT already ignored, so no child can trap it"
else
    # With job control off, Bash sets SIGINT to SIG_IGN for asynchronous commands,
    # and macOS passes that ignore on across exec -- so a suite asserting its own
    # SIGINT handler could not observe the signal. run-all-tests.sh enables job
    # control to avoid that; reproduce the runner's launch model and check that a
    # child still sees SIGINT.
    SIGINT_OUT="$TEST_DIR/sigint-out.txt"
    # Bash 3.2 prints a "[1]+ Done" job notification with job control on; the
    # child's own output goes to the file, so drop the launcher's stderr.
    bash -c 'set -m; ( "$1" > "$2" 2>&1 ) & wait' _ "$SIGINT_CHILD" "$SIGINT_OUT" 2>/dev/null

    if grep -q "TRAP_FIRED" "$SIGINT_OUT"; then
        pass "a suite launched with job control can trap SIGINT"
    else
        fail "SIGINT trappable under job control" "TRAP_FIRED in output" "$(cat "$SIGINT_OUT")"
    fi

    # Now the same launch *without* job control. Whether that loses the signal is
    # itself platform-specific, and that asymmetry is the entire reason for the
    # fix: macOS passes the SIG_IGN on across exec, Linux does not, which is why
    # test-monitor-runtime.sh passed on Linux and failed on macOS. So report which
    # behavior this platform has rather than asserting either one universally.
    SIGINT_PLAIN="$TEST_DIR/sigint-plain.txt"
    bash -c '( "$1" > "$2" 2>&1 ) & wait' _ "$SIGINT_CHILD" "$SIGINT_PLAIN" 2>/dev/null

    if grep -q "TRAP_FIRED" "$SIGINT_PLAIN"; then
        skip "job control is what makes SIGINT trappable" \
            "this platform delivers SIGINT to async children regardless, so set -m is redundant here"
    else
        pass "without job control the same child cannot trap SIGINT, so set -m is what fixes it"
    fi
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
echo "Section 8: Runner contract"

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
echo "Section 9: Bash layer independence from Python"

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
    portable_run_with_timeout 5 bash -c 'exit 3'
    printf '|timeout-status-%s' \"\$?\"
    portable_run_with_timeout 1 sleep 30
    printf '|timeout-fired-%s' \"\$?\"
" 2>&1)

if [[ "$HELPER_PROBE" == *"PYTHON3_WAS_INVOKED"* ]]; then
    fail "helpers avoid python3" "no python3 invocation" "$HELPER_PROBE"
else
    pass "helpers never invoke python3"
fi

EXPECTED_PROBE="ddddddddddddd|2.5s|abc|3|haiku|han-flagged|ascii-clean|timeout-status-3|timeout-fired-124"
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
echo "Section 10: Static guards over tests/"

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
