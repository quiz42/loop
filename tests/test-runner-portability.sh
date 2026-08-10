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
# Static guards cover tests/, hooks/ and scripts/. They stopped at tests/ until
# issue #20, which is how a grep -oP, two GNU-only sed addresses and three
# realpath -m calls stayed in product code through a green suite. The one rule
# still scoped to tests/ is pipefail-grep-q, whose product-code sweep is its own
# issue; its comment in Section 10 says so.
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

# scripts/portable-timeout.sh resolves gtimeout -> timeout -> shell. On the
# macOS runner the first two are absent, so the shell rung is what actually
# runs there; portable_run_with_timeout is that same implementation
# (scripts/lib/shell-timeout.sh), so every assertion below covers the
# production timeout too. The chain used to end in python3 and then in nothing
# at all, which put the Bash layer on Python against ADR-0003.
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

# The status is the command's own even when the caller runs under errexit.
#
# This must be exercised in a separate shell that runs the call UNGUARDED under
# `set -e`. Wrapping the call in `|| rc=$?` (the obvious form) puts it in Bash's
# errexit-ignored conditional context, so the assertion would pass even without
# the `set +e` inside the helper -- a vacuous test. An external child does not
# inherit that OR-list exception, so running the call bare there genuinely
# depends on the helper writing the true status. Without the helper's `set +e`,
# the inherited errexit empties the status file and both cases return 1.
#
# The outer capture stays guarded; it is the inner child that must be unguarded.
run_status_under_errexit() {
    local child_status=0
    bash -c "set -e; source '$SCRIPT_DIR/portable-helpers.sh'; $1" \
        >/dev/null 2>&1 || child_status=$?
    printf '%s' "$child_status"
}

ERREXIT_EXIT=$(run_status_under_errexit "portable_run_with_timeout 5 bash -c 'exit 7'")
if [[ "$ERREXIT_EXIT" == "7" ]]; then
    pass "portable_run_with_timeout returns the command status under an unguarded set -e caller"
else
    fail "portable_run_with_timeout status under set -e" "7" "$ERREXIT_EXIT"
fi

ERREXIT_TIMEOUT=$(run_status_under_errexit "portable_run_with_timeout 1 sleep 5")
if [[ "$ERREXIT_TIMEOUT" == "124" ]]; then
    pass "portable_run_with_timeout returns 124 under an unguarded set -e caller"
else
    fail "portable_run_with_timeout timeout status under set -e" "124" "$ERREXIT_TIMEOUT"
fi

# The bound is on the function, not on output capture. A command that respawns
# into a new process group from a TERM handler escapes the kill -- its group
# leader dies to the signal and the survivor is reparented, so no link remains to
# follow, exactly as for a setsid daemon and exactly as GNU timeout behaves. The
# function still returns within the limit plus grace; a caller whose stdout is a
# pipe (a $( ) capture or a pipeline) would stay open while such an escapee holds
# it. A non-capturing call is used here.
#
# Only the bound is asserted, and it is deliberately not vacuous: the command
# never terminates on its own, so returning 124 within the window is possible
# only if the timeout actually fired and killed it. Whether the TERM handler wins
# its race to spawn the escapee before the KILL is itself timing-dependent -- it
# missed ~1 run in 25 even at a 3s grace -- so asserting the escapee was created
# would just reintroduce a flaky test. The escapee, when it is created, is a short
# `sleep` recorded by pid so this test can reap exactly it (never a global
# `pkill` that would hit other suites in the parallel runner); a missed reap
# self-clears in seconds rather than lingering.
TIMEOUT_ESCAPEE_PID="$TEST_DIR/term-escapee.pid"
rm -f "$TIMEOUT_ESCAPEE_PID"
TIMEOUT_START=$(portable_epoch_ms)
TIMEOUT_STATUS=0
portable_run_with_timeout 1 \
    bash -c 'trap "set -m; sleep 5 & echo \$! > \"\$1\"; wait" TERM
             while :; do sleep 1; done' _ "$TIMEOUT_ESCAPEE_PID" \
    >/dev/null 2>&1 || TIMEOUT_STATUS=$?
TIMEOUT_ELAPSED=$(( $(portable_epoch_ms) - TIMEOUT_START ))
if [[ "$TIMEOUT_STATUS" -eq 124 ]] && [[ "$TIMEOUT_ELAPSED" -lt 15000 ]]; then
    pass "portable_run_with_timeout returns within the bound despite a TERM-handler respawn (${TIMEOUT_ELAPSED}ms)"
else
    fail "portable_run_with_timeout TERM-handler bound" \
        "124 in under 15000 ms" "$TIMEOUT_STATUS in ${TIMEOUT_ELAPSED}ms"
fi
# Best-effort reap of the escapee if the handler did create one, by its recorded
# pid only. Not asserted -- see above.
TIMEOUT_ESCAPEE=$(cat "$TIMEOUT_ESCAPEE_PID" 2>/dev/null || true)
[[ -n "$TIMEOUT_ESCAPEE" ]] && kill -KILL "$TIMEOUT_ESCAPEE" 2>/dev/null || true

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

# Same rule for the runtime shell libraries, which are to the hooks what the
# files above are to the suites: every hook and every entry script inherits
# them, so a Python dependency here is a Python dependency everywhere. Both
# offenders are gone -- portable-timeout.sh's python3 rung (which left a stock
# macOS box with no timeout at all) and project-root.sh's python3
# os.path.realpath fallback -- and this keeps them gone.
#
# Deliberately NOT covered, because each is a different decision than this
# issue's:
#   scripts/loop.sh            proof export|verify|open, which is the Proof
#                              layer ADR-0003 grants Python to.
#   scripts/install-*.sh       install-time JSON merging. Python is a declared
#                              prerequisite there and its absence is a loud
#                              `die`, not a silent degradation.
#   hooks/loop-codex-stop-hook.sh
#                              check-todos-from-transcript.py. A real
#                              hook-layer Python dependency; replacing it means
#                              reimplementing a transcript parser in shell.
#
# One narrow exception inside the covered set: the `$REVIEW_MARKER_SCANNER`
# call in loop-common.sh, which asks proof/core.py where a review marker is
# (ADR-0007).
#
# It is admitted because it is not the shape this rule exists to stop. The two
# offenders it names were fallback rungs inside utilities every code path uses,
# and their absence broke basic behaviour in silence. This one sits on a single
# branch of one function, called by one hook; when python3 is missing it says so
# on stderr and withholds the clean-review record, which is exactly the state
# the loop was in before that record existed. Nothing degrades; one optional
# piece of evidence is not written.
#
# The alternative was tried and failed three times in three review rounds of
# PR #35: a second copy of the marker grammar in awk diverged from
# proof/core.py on column semantics, then on byte versus character offsets for
# non-ASCII prefixes, then on a token spanning a line break -- each divergence
# writing "no finding was reported" about a review the Proof layer reads as
# reporting one, and each reaching `accept`. Measured against the 18 real review
# logs of the M4 dogfood, the only shell rule crude enough to be safe without
# Python (withhold on any `[P` at all) withholds the record from 6 of the 10
# genuinely clean logs, so the safe shell version is not worth having.
#
# The exception is this one call and no other: any further python3 in these
# files still fails, and tests/test-codex-review-merge.sh pins the fail-closed
# behaviour when the scanner cannot run.
#
# "One call" is counted, not pattern-excused. Excusing every line that mentions
# the variable name would let a second invocation ride in on a trailing
# comment; instead, loop-common.sh must contain EXACTLY one non-comment python3
# line, and that line must be, in whole, the approved scanner invocation -- a
# second call sharing the approved line would otherwise ride in the same way.
# Every other covered file must contain none. The whole-line anchor is brittle
# against refactoring on purpose: changing that line means re-arguing the
# ADR-0007 exception, and this failing is how the argument is requested.
RUNTIME_PYTHON_REFS=""
APPROVED_CALL_LINE='^[0-9]+:[[:space:]]*output=\$\(python3 "\$REVIEW_MARKER_SCANNER" "\$file" "\$@" 2>/dev/null\) \|\| status=\$\?$'
for lib in "$PROJECT_ROOT"/hooks/lib/*.sh "$PROJECT_ROOT"/scripts/lib/*.sh "$PROJECT_ROOT/scripts/portable-timeout.sh"; do
    [[ -f "$lib" ]] || continue
    python_lines=$(grep -n 'python3' "$lib" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [[ -z "$python_lines" ]] && continue
    if [[ "${lib##*/}" == "loop-common.sh" ]]; then
        total=$(printf '%s\n' "$python_lines" | grep -c .)
        approved=$(printf '%s\n' "$python_lines" \
            | grep -cE "$APPROVED_CALL_LINE") || true
        if [[ "$total" -ne 1 || "$approved" -ne 1 ]]; then
            RUNTIME_PYTHON_REFS="${RUNTIME_PYTHON_REFS}${lib##*/}(python3-lines=$total,approved=$approved) "
        fi
    else
        RUNTIME_PYTHON_REFS="${RUNTIME_PYTHON_REFS}${lib##*/} "
    fi
done
if [[ -z "$RUNTIME_PYTHON_REFS" ]]; then
    pass "runtime shell libraries hold exactly the one approved python3 call"
else
    fail "runtime shell libraries are Python-free" \
        "one approved scanner call in loop-common.sh, none elsewhere" "$RUNTIME_PYTHON_REFS"
fi

# ========================================
# Static guards
# ========================================

echo ""
echo "Section 10: Static guards over tests/, hooks/ and scripts/"

# Implemented in awk, not Python: this suite is the thing that must not quietly
# acquire a Python dependency (ADR-0003).
#
# The scan covers product code as well as tests. It used to stop at tests/,
# which is why the GNU-only sed addresses in scripts/setup-rlcr-loop.sh, the
# grep -oP in scripts/loop.sh and the realpath -m in the validators all
# survived a green suite (issue #20).
#
# portable-helpers.sh, test-runtime-portability.sh and this file are exempt
# because they are where the portable replacements, these rules and the
# behavioural checks live, so they necessarily name the non-portable forms in
# comments, patterns, tool stubs and assertion messages.
GUARD_OUT="$TEST_DIR/guard-findings.txt"
GUARD_PROG="$TEST_DIR/portability-guard.awk"

# The guard program lives in its own file so the same matcher both scans the
# tree and is exercised against fixtures below. A single-quoted heredoc keeps
# every backslash, dollar, and quote in the program literal.
cat > "$GUARD_PROG" <<'GUARD_AWK'
# Plain `next` rather than the gawk extension `nextfile`, which mawk on
# Ubuntu and the BSD awk on macOS do not both provide.
FILENAME ~ /(portable-helpers|test-runner-portability|test-runtime-portability)\.sh$/ { next }

# Quote and heredoc state carry across lines, so reset both per file.
FNR == 1 { heredoc_tag = ""; heredoc_dash = 0; qstate = "none" }

# Track heredoc bodies. Loop writes prompts and block messages with
# `cat <<'EOF'`, and that markdown routinely contains backticked code spans,
# which are literal text there rather than shell syntax. Only the backtick
# rule consults in_heredoc; every other rule keeps scanning heredoc bodies
# exactly as it did when this guard covered tests/ alone.
{
    in_heredoc = 0
    if (heredoc_tag != "") {
        in_heredoc = 1
        hd_trimmed = $0
        sub(/^[[:space:]]+/, "", hd_trimmed)
        if ($0 == heredoc_tag || (heredoc_dash && hd_trimmed == heredoc_tag)) {
            heredoc_tag = ""
        }
    } else if (qstate == "none" && $0 !~ /^[[:space:]]*#/) {
        hd_scan = $0
        gsub(/<<</, "@@@", hd_scan)
        if (match(hd_scan, /<<-?[[:space:]]*("[A-Za-z_][A-Za-z0-9_]*"|'[A-Za-z_][A-Za-z0-9_]*'|[A-Za-z_][A-Za-z0-9_]*)/)) {
            hd_tok = substr(hd_scan, RSTART, RLENGTH)
            heredoc_dash = (hd_tok ~ /^<<-/)
            sub(/^<<-?[[:space:]]*/, "", hd_tok)
            gsub(/"/, "", hd_tok)
            gsub(/'/, "", hd_tok)
            heredoc_tag = hd_tok
        }
    }
}

# A backtick that is neither escaped nor inside single quotes is command
# substitution -- including in the middle of a double-quoted message body,
# which is how a block message containing `goal-tracker.md` came to run the
# filename as a command and print it as nothing (issue #20 item 1), and how
# nine assertions in test-refine-plan.sh came to compare against "- ". The
# repo writes $( ) for real substitution, so the rule is: no live backtick.
# Use \` for a literal one.
#
# Unlike the pipefail race below, shell quote state is decidable, so this is a
# character scanner with cross-line state rather than a regex. A per-line
# regex cannot do it: single-quoted awk programs run for dozens of lines with
# backticked markdown fences inside them, and an apostrophe in a double-quoted
# sentence must not be mistaken for the start of a quoted span.
{
    live_backtick = 0
    if (!in_heredoc) {
        live_backtick = scan_for_live_backtick($0)
    }
}
live_backtick {
    report("live-backtick", "unescaped backtick runs as a command substitution; write \\` for a literal")
}

# Skip comment lines for the rules below: naming a construct in prose is not
# using it. The scanner above already ran, because a comment line inside a
# multi-line quoted span still carries quote state.
/^[[:space:]]*#/ { next }

# The rules below match probe_line: the record with any trailing comment
# removed. They used to write [^#] inline to mean "stop before a comment", but
# a sed script carries #s of its own ('/^## Goal/'), which blinded the GNU-BRE
# rule to exactly the address in scripts/setup-rlcr-loop.sh it exists to catch.
{
    probe_line = $0
    sub(/[[:space:]]#.*/, "", probe_line)
}

# BSD sed rejects a nested brace block. The outer brace must open an address
# block ("{ /^key:/{ ... }") so that sed handling "{{PLACEHOLDER}}" text is
# not mistaken for one.
probe_line ~ /(^|[^[:alnum:]_])sed[^|]*\{[[:space:]]*\/[^{}]*\{/ {
    report("nested-sed", "nested brace block in a sed script; BSD sed rejects it")
}

# \+, \? and \| inside a BRE are GNU extensions; BSD sed treats them
# literally and silently produces wrong output.
probe_line ~ /(^|[^[:alnum:]_])sed[^|]*\\[+?|]/ {
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

# BSD realpath has no -m and fails outright on a component that does not exist
# yet, so `realpath -m "$out" || echo "$out"` yields the raw relative input on
# macOS where Linux yields an absolute path -- and an assertion built with the
# same call degrades with it instead of failing.
probe_line ~ /(^|[^[:alnum:]_])realpath[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*m/ {
    report("gnu-realpath-m", "realpath -m; BSD realpath has no -m, use portable_abs_path")
}

# `echo`/`printf` writing a variable, piped directly into a quiet `grep`, races
# under pipefail: grep exits on the match and closes the pipe, the still-writing
# builtin takes SIGPIPE, the pipeline reports 141, and a matching assertion reads
# as false (issue #22). Use `[[ "$var" == *lit* ]]` or a here-string
# `grep ... <<< "$var"`.
#
# This is a regression tripwire for that specific idiom, not a sound analyzer:
# detecting the race in general is undecidable -- it depends on the runtime
# payload size and where the match falls, and any producer that outruns the pipe
# buffer is equally racy. The rule deliberately covers only the direct
# `echo|printf ... | grep` form, and within it is getopt-accurate. Quoted flags
# are unquoted so `"-q"` is still seen; quoted patterns are blanked so a `q`
# inside them is not; `--` ends options and -e/-f/-m/-A/-B/-C/-D/-d consume their
# argument -- so `grep -e -q`, `grep -- -q`, and `grep -eq foo` (where -q/q is an
# operand) are NOT flagged, while every quiet position is (`-q`, `-iq`, `-qe`,
# `grep X -q`, `grep -e X -q`, `--quiet`/`--silent`). Out of scope, left to code
# review: intermediate stages (`echo | tr | grep -q`), env/command prefixes
# (`LC_ALL=C grep -q`), line continuations, indirection (`f=-q; grep $f`), and
# non-echo producers -- a reintroduction through any of those still surfaces as
# CI flakiness.
#
# check_pipefail gates this rule to tests/. The same idiom appears about fifty
# times in hooks/ and scripts/, which do run under `set -o pipefail`; sweeping
# those is the same mechanical change issue #22 made to tests/ and belongs in
# its own issue rather than folded into a portability fix.
check_pipefail == 1 {
    probe = unquote_opts($0)
    gsub(/"[^"]*"/, "@", probe)
    gsub(/'[^']*'/, "@", probe)
    sub(/[[:space:]]#.*/, "", probe)
    # printf -v writes to a variable, not stdout, so it is not a producer.
    if (probe !~ /(^|[^[:alnum:]_])printf[^|]*-v[[:space:]]/ &&
        probe ~ /(^|[^[:alnum:]_])(echo|printf)[^[:alnum:]_][^|#;&]*\|[[:space:]]*grep([^[:alnum:]_]|$)/) {
        args = probe
        sub(/^.*\|[[:space:]]*grep/, "", args)
        sub(/[|;&].*/, "", args)
        if (quiet_in_options(args)) {
            report("pipefail-grep-q", "echo/printf piped into a quiet grep races under pipefail; use [[ == *lit* ]] or a here-string")
        }
    }
}

# Walk one record, carrying shell quote state across lines in qstate, and
# report whether it contains a live backtick. Returns 1 at the first one.
#
# Rules applied: a backslash escapes the next character outside single quotes;
# single quotes take everything literally until the next single quote (no
# escapes there, which is why the single-quote branch comes first); double
# quotes end at the next unescaped double quote and keep backticks live; and an
# unquoted # that starts a word begins a comment, so ${var#pat} and a=b#c are
# not mistaken for one.
function scan_for_live_backtick(line,   i, c, n) {
    n = length(line)
    i = 1
    while (i <= n) {
        c = substr(line, i, 1)
        if (qstate == "single") {
            if (c == "'") { qstate = "none" }
            i++
            continue
        }
        if (c == "\\") { i += 2; continue }
        if (qstate == "double") {
            if (c == "\"") { qstate = "none" }
            else if (c == "`") { return 1 }
            i++
            continue
        }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];&|()]/)) { return 0 }
        if (c == "'") { qstate = "single"; i++; continue }
        if (c == "\"") { qstate = "double"; i++; continue }
        if (c == "`") { return 1 }
        i++
    }
    return 0
}

# Within grep's argument string, is a quiet option present in option position?
# Applies grep getopt semantics: `--` ends option parsing, and -e/-f/-m/-A/-B/-C/
# -D/-d consume an argument, so a q that is such an argument is not the quiet flag.
function quiet_in_options(s,   a, n, i, t, optsended, j, ch, argtaking) {
    n = split(s, a, /[[:space:]]+/)
    optsended = 0
    argtaking = "efmABCDd"
    for (i = 1; i <= n; i++) {
        t = a[i]
        if (t == "") continue
        if (optsended) continue
        if (t == "--") { optsended = 1; continue }
        if (t ~ /^--/) {
            if (t == "--quiet" || t == "--silent") return 1
            if (t == "--regexp" || t == "--file" || t == "--regex") { i++ }
            continue
        }
        if (t ~ /^-.+/) {
            for (j = 2; j <= length(t); j++) {
                ch = substr(t, j, 1)
                if (index(argtaking, ch) > 0) { if (j == length(t)) i++; break }
                if (ch == "q") return 1
            }
            continue
        }
    }
    return 0
}

# Strip the quotes from quoted tokens that are options ("-q" -> -q), so quoting a
# flag cannot hide it; quoted patterns are blanked separately by the caller.
function unquote_opts(s,   out, tok, inner) {
    out = ""
    while (match(s, /"-[^"[:space:]]*"|'-[^'[:space:]]*'/)) {
        tok = substr(s, RSTART, RLENGTH)
        inner = substr(tok, 2, length(tok) - 2)
        out = out substr(s, 1, RSTART - 1) inner
        s = substr(s, RSTART + RLENGTH)
    }
    return out s
}

function report(rule, message) {
    printf "%s:%d: %s: %s\n", FILENAME, FNR, rule, message
}
GUARD_AWK

# Two passes because check_pipefail differs: tests/ gets every rule, product
# code gets every rule except pipefail-grep-q (see the rule's own comment).
find "$SCRIPT_DIR" -name '*.sh' -type f -print0 2>/dev/null \
    | xargs -0 awk -v check_pipefail=1 -f "$GUARD_PROG" > "$GUARD_OUT" 2>&1
find "$PROJECT_ROOT/hooks" "$PROJECT_ROOT/scripts" -name '*.sh' -type f -print0 2>/dev/null \
    | xargs -0 awk -v check_pipefail=0 -f "$GUARD_PROG" >> "$GUARD_OUT" 2>&1

if [[ ! -s "$GUARD_OUT" ]]; then
    pass "no non-portable shell constructs in tests/, hooks/ or scripts/"
else
    fail "non-portable shell constructs in tests/, hooks/ or scripts/" "no findings" "$(cat "$GUARD_OUT")"
fi

# The scan above is only as good as the files it reaches, and a find that
# silently matched nothing would report "clean" for the whole tree.
GUARD_SCANNED=$(find "$SCRIPT_DIR" "$PROJECT_ROOT/hooks" "$PROJECT_ROOT/scripts" \
    -name '*.sh' -type f 2>/dev/null | portable_count_lines)
if [[ "$GUARD_SCANNED" -ge 60 ]]; then
    pass "static guard scanned $GUARD_SCANNED shell files across tests/, hooks/ and scripts/"
else
    fail "static guard scan coverage" ">= 60 shell files" "$GUARD_SCANNED"
fi

# Positive and negative coverage for the pipefail grep -q guard. This file and
# portable-helpers.sh are exempt from the scan above (they necessarily name the
# forbidden forms), so the rule's own detection is asserted here against
# fixtures. Positives exercise every quiet position (leading, reordered and
# before-e bundles, after -e / after a positional, --quiet, a quoted flag, and a
# chained condition). Negatives cover the safe forms (here-string, real-command
# pipeline, grep -c, a `q` inside a quoted pattern), the getopt cases where -q/q
# is an operand rather than the flag (grep -e -q, grep -eq X, grep -- -q,
# grep X -- -q, grep -fq X), an `echo`-prefixed variable name, a non-echo
# producer after a `;`, and an inline comment.
GUARD_POS="$TEST_DIR/guard-grep-q-positive.sh"
cat > "$GUARD_POS" <<'GUARD_POS_EOF'
echo "$OUTPUT" | grep -q "leading"
echo "$OUTPUT" | grep -qi "short-bundle"
echo "$OUTPUT" | grep -iq "reordered-bundle"
echo "$OUTPUT" | grep -qe "before-e-in-bundle"
echo "$OUTPUT" | grep -e "^1$" -q
echo "$OUTPUT" | grep "positional" -q
echo "$OUTPUT" | grep --quiet "long-form"
echo "$OUTPUT" | grep "-q" "^1$"
printf '%s' "$OUTPUT" | grep -q "printf-producer"
if [[ $rc -eq 0 ]] && echo "$OUTPUT" | grep -q "chained"; then :; fi
GUARD_POS_EOF

GUARD_NEG="$TEST_DIR/guard-grep-q-negative.sh"
cat > "$GUARD_NEG" <<'GUARD_NEG_EOF'
grep -q "herestring" <<< "$OUTPUT"
head -1 "$file" | grep -q "^---$"
git rev-parse 2>/dev/null | grep -q ":"
echo "$OUTPUT" | grep -c "count-not-quiet"
echo "$OUTPUT" | grep "mentions -q inside a literal"
echo "$OUTPUT" | grep -e -q
echo "$OUTPUT" | grep -eq operand
echo "$OUTPUT" | grep -- -q
echo "$OUTPUT" | grep needle -- -q
echo "$OUTPUT" | grep -fq patternfile
echo_result="$OUTPUT" | grep -q assigned-not-echoed
echo begin; true | grep -q producer-is-true
[[ "$OUTPUT" == *"literal"* ]]
echo "$OUTPUT" | cat > /dev/null  # echo foo | grep -q inside-a-comment
GUARD_NEG_EOF

awk -v check_pipefail=1 -f "$GUARD_PROG" "$GUARD_POS" > "$TEST_DIR/guard-pos-out.txt" 2>&1
awk -v check_pipefail=1 -f "$GUARD_PROG" "$GUARD_NEG" > "$TEST_DIR/guard-neg-out.txt" 2>&1
GUARD_POS_HITS=$(grep -c 'pipefail-grep-q' "$TEST_DIR/guard-pos-out.txt" || true)
GUARD_NEG_HITS=$(grep -c 'pipefail-grep-q' "$TEST_DIR/guard-neg-out.txt" || true)
if [[ "$GUARD_POS_HITS" -eq 10 && "$GUARD_NEG_HITS" -eq 0 ]]; then
    pass "pipefail grep -q guard flags every quiet position and no safe or non-quiet form"
else
    fail "pipefail grep -q guard coverage" "10 positive hits and 0 negative hits" \
        "positives=$GUARD_POS_HITS negatives=$GUARD_NEG_HITS"
fi

# check_pipefail=0 must silence that rule and only that rule, which is what
# lets product code be scanned before its own sweep lands.
awk -v check_pipefail=0 -f "$GUARD_PROG" "$GUARD_POS" > "$TEST_DIR/guard-pos-off.txt" 2>&1
GUARD_OFF_HITS=$(grep -c 'pipefail-grep-q' "$TEST_DIR/guard-pos-off.txt" || true)
if [[ "$GUARD_OFF_HITS" -eq 0 ]]; then
    pass "pipefail grep -q rule is gated off by check_pipefail=0"
else
    fail "pipefail grep -q gating" "0 hits with check_pipefail=0" "$GUARD_OFF_HITS"
fi

# Every other rule, positive and negative, against fixtures rather than against
# the tree: the tree is clean by construction once the fixes land, so a rule
# that matched nothing at all would look exactly the same as a rule that works.
#
# The positives are the real defects issue #20 fixed, verbatim. Note line 3:
# the GNU-BRE address carries a # of its own, which the previous [^#] form of
# the rule could not see past -- the case that let this defect ship.
GUARD_RULES_POS="$TEST_DIR/guard-rules-positive.sh"
cat > "$GUARD_RULES_POS" <<'GUARD_RULES_POS_EOF'
local fallback="Do not modify `goal-tracker.md` via Bash"
assert_file_contains "$FILE" "- `## Goal Description`" "reads as - and nothing else"
goal=$(sed -n '/^##[[:space:]]*[Gg]oal\|^##[[:space:]]*[Oo]bjective/,/^##/p' "$plan")
value=$(sed -n 's/^x\+//p' "$f")
round=$(grep -oP '(?<=^build_finish_round=)\d+' "$marker")
OUTPUT_FILE=$(realpath -m "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
INPUT_FILE=$(realpath -q -m "$INPUT_FILE")
stamp=$(date +%s%3N)
lower="${NAME,,}"
sed -n '/^---$/,/^---$/{ /^key:/{ s/^key://p; q; } }' "$f"
msg="a double-quoted body that runs for
more than one line and mentions `a-file.md` on the second"
GUARD_RULES_POS_EOF

GUARD_RULES_NEG="$TEST_DIR/guard-rules-negative.sh"
cat > "$GUARD_RULES_NEG" <<'GUARD_RULES_NEG_EOF'
local fallback="Do not modify \`goal-tracker.md\` via Bash"
assert_file_contains "$FILE" '- `## Goal Description`' "single quotes keep it literal"
goal=$(sed -nE '/^##[[:space:]]*([Gg]oal|[Oo]bjective)/,/^##/p' "$plan")
round=$(sed -nE 's/^build_finish_round=([0-9]+).*/\1/p' "$marker")
OUTPUT_FILE=$(portable_abs_path "$OUTPUT_FILE")
stamp=$(portable_epoch_ms)
lower=$(portable_to_lower "$NAME")
awk '
    function update_fence(line) {
        if (!in_fence && line ~ /^```/) { in_fence = 1; return }
        if (in_fence && line ~ /^```/) { in_fence = 0 }
    }
' "$f"
note="do not write to an old loop session's tracker"
after="the apostrophe above must not open a quoted span"
cat >> "$prompt_file" << 'ROUTING_EOF'
- `coding` task -> Claude executes directly
- `analyze` task -> via `/rloop:ask-codex`
ROUTING_EOF
# a comment naming `backticks`, sed \| , realpath -m and grep -P is prose
value="${var#prefix}"
GUARD_RULES_NEG_EOF

awk -v check_pipefail=0 -f "$GUARD_PROG" "$GUARD_RULES_POS" > "$TEST_DIR/guard-rules-pos-out.txt" 2>&1
awk -v check_pipefail=0 -f "$GUARD_PROG" "$GUARD_RULES_NEG" > "$TEST_DIR/guard-rules-neg-out.txt" 2>&1

GUARD_RULE_FAILURES=""
# rule name : how many fixture lines must trip it
for rule_expectation in \
    "live-backtick:3" \
    "gnu-sed-bre:2" \
    "grep-pcre:1" \
    "gnu-realpath-m:2" \
    "raw-epoch-ns:1" \
    "bash4-case:1" \
    "nested-sed:1"
do
    rule_name="${rule_expectation%%:*}"
    rule_want="${rule_expectation##*:}"
    rule_got=$(grep -c "$rule_name" "$TEST_DIR/guard-rules-pos-out.txt" || true)
    if [[ "$rule_got" -ne "$rule_want" ]]; then
        GUARD_RULE_FAILURES="${GUARD_RULE_FAILURES}${rule_name} want=${rule_want} got=${rule_got}; "
    fi
done
if [[ -z "$GUARD_RULE_FAILURES" ]]; then
    pass "every static guard rule flags its own defect fixture"
else
    fail "static guard rule positives" "each rule hits its fixture lines" "$GUARD_RULE_FAILURES"
fi

if [[ ! -s "$TEST_DIR/guard-rules-neg-out.txt" ]]; then
    pass "no static guard rule fires on the portable forms, quoted heredocs or prose"
else
    fail "static guard rule negatives" "no findings" "$(cat "$TEST_DIR/guard-rules-neg-out.txt")"
fi

print_test_summary "Runner Portability Test Summary"
