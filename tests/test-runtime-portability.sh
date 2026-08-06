#!/usr/bin/env bash
#
# Behavioural portability tests for the Loop runtime (hooks/ and scripts/).
#
# tests/test-runner-portability.sh covers the test runner and its helpers, and
# its Section 10 static guards stop the non-portable idioms from being written
# again. This suite covers the other half: that the product code actually
# produces the right answer on both userlands.
#
# Every defect here shipped green on Linux and was wrong only on macOS, or was
# wrong everywhere while looking fine (issue #20):
#
#   - A block message built in double quotes around `goal-tracker.md` ran the
#     filename as a command, on every platform.
#   - grep -oP with a lookbehind returned nothing under BSD grep, so the
#     monitor lost its round numbers.
#   - \| alternation in a sed address is a GNU extension, so BSD sed returned
#     an empty plan Goal and an empty Acceptance Criteria section.
#   - GNU date -d does not exist on BSD, so the monitor showed a raw UTC ISO
#     string instead of local time.
#   - realpath -m does not exist on BSD, so validators reported a raw relative
#     path where Linux reported an absolute one.
#
# Where the fix is about tolerating a missing GNU option, the assertion is made
# twice: once against the host's own tools, and once with a stub first on PATH
# that removes the option the way the other userland does. That second run is
# what makes these tests mean the same thing on the Ubuntu and macOS runners
# rather than passing for free on one of them.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Runtime Portability Tests"
echo "========================================"
echo ""

# ========================================
# Block messages
# ========================================

echo "Section 1: Block message builders"

# TEMPLATE_DIR is pointed at nothing so the built-in fallback string is what
# gets rendered -- the fallback is the thing that contained the live backticks.
BLOCK_STDERR="$TEST_DIR/goal-tracker-block-stderr.txt"
BLOCK_MESSAGE=$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" "$BASH" -c "
    set -uo pipefail
    source '$PROJECT_ROOT/hooks/lib/loop-common.sh'
    TEMPLATE_DIR=/nonexistent-template-dir
    goal_tracker_blocked_message 3 /tmp/loop-x/goal-tracker.md
" 2>"$BLOCK_STDERR")

if [[ "$BLOCK_MESSAGE" == *'`goal-tracker.md`'* ]]; then
    pass "goal-tracker block message keeps the literal \`goal-tracker.md\`"
else
    fail "goal-tracker block message filename" '`goal-tracker.md`' "$BLOCK_MESSAGE"
fi

if [[ ! -s "$BLOCK_STDERR" ]]; then
    pass "goal-tracker block message writes nothing to stderr"
else
    fail "goal-tracker block message stderr" "(nothing)" "$(cat "$BLOCK_STDERR")"
fi

if [[ "$BLOCK_MESSAGE" == *"Round 3"* && "$BLOCK_MESSAGE" == *"/tmp/loop-x/goal-tracker.md"* ]]; then
    pass "goal-tracker block message still renders its placeholders"
else
    fail "goal-tracker block message placeholders" "Round 3 and the correct path" "$BLOCK_MESSAGE"
fi

# ========================================
# Monitor: round numbers
# ========================================

echo ""
echo "Section 2: Monitor round parsing without PCRE"

# shellcheck source=scripts/lib/monitor-common.sh
source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

MARKER_FILE="$TEST_DIR/.review-phase-started"
echo "build_finish_round=7" > "$MARKER_FILE"

PARSED_ROUND=$(monitor_read_build_finish_round "$MARKER_FILE")
if [[ "$PARSED_ROUND" == "7" ]]; then
    pass "monitor_read_build_finish_round reads the marker"
else
    fail "monitor_read_build_finish_round" "7" "$PARSED_ROUND"
fi

# A grep that rejects -P, which is what BSD grep does. On the macOS runner the
# real grep already behaves this way; the stub makes the Ubuntu runner assert
# the same thing instead of passing for free.
BSD_TOOLS_BIN="$TEST_DIR/bsd-tools-bin"
mkdir -p "$BSD_TOOLS_BIN"
REAL_GREP="$(command -v grep)"
cat > "$BSD_TOOLS_BIN/grep" <<STUB
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        --) break ;;
        -*P*) echo "grep: invalid option -- P" >&2; exit 2 ;;
    esac
done
exec "$REAL_GREP" "\$@"
STUB
chmod +x "$BSD_TOOLS_BIN/grep"

PARSED_ROUND_NO_PCRE=$(PATH="$BSD_TOOLS_BIN:$PATH" "$BASH" -c "
    source '$PROJECT_ROOT/scripts/lib/monitor-common.sh'
    monitor_read_build_finish_round '$MARKER_FILE'
" 2>/dev/null)
if [[ "$PARSED_ROUND_NO_PCRE" == "7" ]]; then
    pass "monitor_read_build_finish_round works with a grep that has no -P"
else
    fail "monitor round parse without PCRE" "7" "$PARSED_ROUND_NO_PCRE"
fi

# The stub has to actually reject -P, or the assertion above proves nothing.
if PATH="$BSD_TOOLS_BIN:$PATH" grep -oP 'x' /dev/null 2>/dev/null; then
    fail "BSD grep stub rejects -P" "non-zero exit" "grep -P succeeded"
else
    pass "BSD grep stub rejects -P, so the check above is not vacuous"
fi

MISSING_MARKER_ROUND=$(monitor_read_build_finish_round "$TEST_DIR/no-such-marker")
if [[ -z "$MISSING_MARKER_ROUND" ]]; then
    pass "monitor_read_build_finish_round is empty for a missing marker"
else
    fail "monitor round parse missing marker" "(empty)" "$MISSING_MARKER_ROUND"
fi

# ========================================
# Monitor: local time
# ========================================

echo ""
echo "Section 3: Monitor timestamp rendering in local time"

# Fixed zones give fixed expected strings, so the assertion does not depend on
# the date implementation it is testing. 2026-01-29T18:45:46Z is 13:45:46 in
# New York (EST, UTC-5) and 03:45:46 the next day in Berlin (CET, UTC+1).
LOCAL_UTC=$(TZ=UTC monitor_utc_iso_to_local "2026-01-29T18:45:46Z")
LOCAL_NY=$(TZ=America/New_York monitor_utc_iso_to_local "2026-01-29T18:45:46Z")
LOCAL_BERLIN=$(TZ=Europe/Berlin monitor_utc_iso_to_local "2026-01-29T18:45:46Z")

if [[ "$LOCAL_UTC" == "2026-01-29 18:45:46" ]]; then
    pass "monitor_utc_iso_to_local renders UTC unchanged"
else
    fail "monitor_utc_iso_to_local UTC" "2026-01-29 18:45:46" "$LOCAL_UTC"
fi

if [[ "$LOCAL_NY" == "2026-01-29 13:45:46" ]]; then
    pass "monitor_utc_iso_to_local converts to America/New_York"
else
    fail "monitor_utc_iso_to_local New_York" "2026-01-29 13:45:46" "$LOCAL_NY"
fi

if [[ "$LOCAL_BERLIN" == "2026-01-29 19:45:46" ]]; then
    pass "monitor_utc_iso_to_local converts to Europe/Berlin"
else
    fail "monitor_utc_iso_to_local Berlin" "2026-01-29 19:45:46" "$LOCAL_BERLIN"
fi

# Force the branch this host does not normally take. On a GNU host the stub
# removes -d and emulates BSD's -j -f / -r with the real GNU date, so the BSD
# branch is exercised on Linux; on a BSD host date -d already fails, so the
# assertions above were the BSD branch and the stub instead proves the helper
# degrades to the input rather than to a wrong time.
REAL_DATE="$(command -v date)"
if date -d "2026-01-29 18:45:46 UTC" '+%Y' >/dev/null 2>&1; then
    cat > "$BSD_TOOLS_BIN/date" <<STUB
#!/bin/sh
# BSD-shaped date on top of a GNU one: no -d, and -j -f/-r are translated.
case "\$1" in
    -d|--date|--date=*) echo "date: illegal option -- d" >&2; exit 1 ;;
esac
if [ "\$1" = "-j" ] && [ "\$2" = "-f" ]; then
    exec "$REAL_DATE" -d "\$4" "\$5"
fi
if [ "\$1" = "-r" ]; then
    exec "$REAL_DATE" -d "@\$2" "\$3"
fi
if [ "\$1" = "-u" ] && [ "\$2" = "-r" ]; then
    exec "$REAL_DATE" -u -d "@\$3" "\$4"
fi
exec "$REAL_DATE" "\$@"
STUB
    chmod +x "$BSD_TOOLS_BIN/date"
    LOCAL_NY_BSD=$(PATH="$BSD_TOOLS_BIN:$PATH" TZ=America/New_York "$BASH" -c "
        source '$PROJECT_ROOT/scripts/lib/monitor-common.sh'
        monitor_utc_iso_to_local '2026-01-29T18:45:46Z'
    " 2>/dev/null)
    if [[ "$LOCAL_NY_BSD" == "2026-01-29 13:45:46" ]]; then
        pass "monitor_utc_iso_to_local converts through the BSD date branch"
    else
        fail "monitor_utc_iso_to_local BSD branch" "2026-01-29 13:45:46" "$LOCAL_NY_BSD"
    fi
else
    cat > "$BSD_TOOLS_BIN/date" <<STUB
#!/bin/sh
case "\$1" in
    -j|-r) echo "date: unsupported" >&2; exit 1 ;;
esac
case "\$2" in
    -r) echo "date: unsupported" >&2; exit 1 ;;
esac
exec "$REAL_DATE" "\$@"
STUB
    chmod +x "$BSD_TOOLS_BIN/date"
    LOCAL_NO_DATE=$(PATH="$BSD_TOOLS_BIN:$PATH" "$BASH" -c "
        source '$PROJECT_ROOT/scripts/lib/monitor-common.sh'
        monitor_utc_iso_to_local '2026-01-29T18:45:46Z'
    " 2>/dev/null)
    if [[ "$LOCAL_NO_DATE" == "2026-01-29T18:45:46Z" ]]; then
        pass "monitor_utc_iso_to_local returns the input when no date branch works"
    else
        fail "monitor_utc_iso_to_local no-date fallback" "2026-01-29T18:45:46Z" "$LOCAL_NO_DATE"
    fi
fi

UNPARSEABLE=$(monitor_utc_iso_to_local "not-a-timestamp")
if [[ "$UNPARSEABLE" == "not-a-timestamp" ]]; then
    pass "monitor_utc_iso_to_local passes an unparseable value through"
else
    fail "monitor_utc_iso_to_local unparseable" "not-a-timestamp" "$UNPARSEABLE"
fi

# ========================================
# Absolute paths without realpath -m
# ========================================

echo ""
echo "Section 4: Absolute path resolution without realpath -m"

# shellcheck source=hooks/lib/project-root.sh
source "$PROJECT_ROOT/hooks/lib/project-root.sh"

ABS_ROOT="$TEST_DIR/abs"
mkdir -p "$ABS_ROOT/real/sub"
ln -s "$ABS_ROOT/real" "$ABS_ROOT/link"
touch "$ABS_ROOT/real/file.txt"
ABS_ROOT_REAL="$(cd "$ABS_ROOT" && pwd -P)"

ABS_EXISTING=$(portable_abs_path "$ABS_ROOT/real/sub")
if [[ "$ABS_EXISTING" == "$ABS_ROOT_REAL/real/sub" ]]; then
    pass "portable_abs_path resolves an existing directory"
else
    fail "portable_abs_path existing directory" "$ABS_ROOT_REAL/real/sub" "$ABS_EXISTING"
fi

ABS_MISSING=$(portable_abs_path "$ABS_ROOT/real/not-created-yet.md")
if [[ "$ABS_MISSING" == "$ABS_ROOT_REAL/real/not-created-yet.md" ]]; then
    pass "portable_abs_path resolves a file that does not exist yet"
else
    fail "portable_abs_path missing leaf" "$ABS_ROOT_REAL/real/not-created-yet.md" "$ABS_MISSING"
fi

ABS_DEEP=$(portable_abs_path "$ABS_ROOT/real/no/such/deep/plan.md")
if [[ "$ABS_DEEP" == "$ABS_ROOT_REAL/real/no/such/deep/plan.md" ]]; then
    pass "portable_abs_path resolves a missing tail of any depth"
else
    fail "portable_abs_path deep missing tail" "$ABS_ROOT_REAL/real/no/such/deep/plan.md" "$ABS_DEEP"
fi

ABS_SYMLINKED=$(portable_abs_path "$ABS_ROOT/link/no/such/plan.md")
if [[ "$ABS_SYMLINKED" == "$ABS_ROOT_REAL/real/no/such/plan.md" ]]; then
    pass "portable_abs_path resolves a symlinked prefix under a missing tail"
else
    fail "portable_abs_path symlinked prefix" "$ABS_ROOT_REAL/real/no/such/plan.md" "$ABS_SYMLINKED"
fi

ABS_RELATIVE=$(cd "$ABS_ROOT/real" && portable_abs_path "sub/../refined-plan.md")
if [[ "$ABS_RELATIVE" == "$ABS_ROOT_REAL/real/refined-plan.md" ]]; then
    pass "portable_abs_path absolutizes a relative path and folds .."
else
    fail "portable_abs_path relative input" "$ABS_ROOT_REAL/real/refined-plan.md" "$ABS_RELATIVE"
fi

if [[ -z "$(portable_abs_path "")" ]]; then
    pass "portable_abs_path prints nothing for empty input"
else
    fail "portable_abs_path empty input" "(nothing)" "$(portable_abs_path "")"
fi

# With realpath unusable the builtin-only path has to give the same answers.
# This is also the ADR-0003 assertion: what used to fill this gap was
# python3 -c os.path.realpath.
NO_TOOLS_BIN="$TEST_DIR/no-tools-bin"
mkdir -p "$NO_TOOLS_BIN"
cat > "$NO_TOOLS_BIN/realpath" <<'STUB'
#!/bin/sh
echo "REALPATH_WAS_INVOKED" >&2
exit 1
STUB
chmod +x "$NO_TOOLS_BIN/realpath"
cat > "$NO_TOOLS_BIN/python3" <<'STUB'
#!/bin/sh
echo "PYTHON3_WAS_INVOKED" >&2
exit 127
STUB
chmod +x "$NO_TOOLS_BIN/python3"

NO_REALPATH_PROBE=$(PATH="$NO_TOOLS_BIN:$PATH" "$BASH" -c "
    source '$PROJECT_ROOT/hooks/lib/project-root.sh'
    printf '%s|%s|%s' \
        \"\$(portable_abs_path '$ABS_ROOT/real/sub')\" \
        \"\$(portable_abs_path '$ABS_ROOT/link/no/such/plan.md')\" \
        \"\$(canonicalize_path_prefix '$ABS_ROOT/link/state.md')\"
" 2>&1)
NO_REALPATH_EXPECTED="$ABS_ROOT_REAL/real/sub|$ABS_ROOT_REAL/real/no/such/plan.md|$ABS_ROOT_REAL/real/state.md"
if [[ "$NO_REALPATH_PROBE" == "$NO_REALPATH_EXPECTED" ]]; then
    pass "path helpers give the same answers with realpath unusable"
else
    fail "path helpers without realpath" "$NO_REALPATH_EXPECTED" "$NO_REALPATH_PROBE"
fi

if [[ "$NO_REALPATH_PROBE" == *"PYTHON3_WAS_INVOKED"* ]]; then
    fail "path helpers avoid python3" "no python3 invocation" "$NO_REALPATH_PROBE"
else
    pass "path helpers never fall back to python3"
fi

# ========================================
# Validators report absolute paths
# ========================================

echo ""
echo "Section 5: Validators report an absolute output path"

VALIDATOR_PLAN_DIR="$TEST_DIR/validator-plan"
mkdir -p "$VALIDATOR_PLAN_DIR/out"
cat > "$VALIDATOR_PLAN_DIR/draft.md" <<'PLAN_EOF'
# Draft

## Goal
Ship the thing.

## Notes
More than five lines of content so the validator is happy.
Line six.
Line seven.
PLAN_EOF

VALIDATOR_PLAN_DIR_REAL="$(cd "$VALIDATOR_PLAN_DIR" && pwd -P)"
VALIDATOR_OUT=$(cd "$VALIDATOR_PLAN_DIR" && "$PROJECT_ROOT/scripts/validate-gen-plan-io.sh" \
    --input draft.md --output out/plan.md 2>&1) || true

if [[ "$VALIDATOR_OUT" == *"Output file: $VALIDATOR_PLAN_DIR_REAL/out/plan.md"* ]]; then
    pass "validate-gen-plan-io reports an absolute output path for a relative argument"
else
    fail "validate-gen-plan-io absolute output path" \
        "Output file: $VALIDATOR_PLAN_DIR_REAL/out/plan.md" "$VALIDATOR_OUT"
fi

if [[ "$VALIDATOR_OUT" == *"Input file: $VALIDATOR_PLAN_DIR_REAL/draft.md"* ]]; then
    pass "validate-gen-plan-io reports an absolute input path for a relative argument"
else
    fail "validate-gen-plan-io absolute input path" \
        "Input file: $VALIDATOR_PLAN_DIR_REAL/draft.md" "$VALIDATOR_OUT"
fi

# ========================================
# Plan section extraction
# ========================================

echo ""
echo "Section 6: Plan Goal and Acceptance Criteria extraction"

# End to end through setup-rlcr-loop.sh, because the sed addresses that used to
# fail under BSD sed feed the generated goal tracker. Distinctive sentences so
# a partial match cannot pass by accident.
PLAN_REPO="$TEST_DIR/plan-repo"
mkdir -p "$PLAN_REPO"
(
    cd "$PLAN_REPO" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo "seed" > seed.txt
    git add seed.txt
    git commit -qm "seed"
) >/dev/null 2>&1

SETUP_DEPS_MISSING=""
for dep in git codex jq; do
    command -v "$dep" >/dev/null 2>&1 || SETUP_DEPS_MISSING="${SETUP_DEPS_MISSING}${dep} "
done

cat > "$PLAN_REPO/plan.md" <<'PLAN_EOF'
# Implementation Plan

## Goal
Carry the goal sentence into the generated tracker.

## Acceptance Criteria
- Carry the acceptance sentence into the generated tracker.

## Steps
1. First step
2. Second step
PLAN_EOF

# setup-rlcr-loop.sh refuses to start on a dirty tree, and refuses a tracked
# plan file without --track-plan-file, so the plan is committed and that flag
# is passed.
(
    cd "$PLAN_REPO" || exit 1
    git add plan.md
    git commit -qm "add plan"
) >/dev/null 2>&1

(
    cd "$PLAN_REPO" || exit 1
    CLAUDE_PROJECT_DIR="$PLAN_REPO" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --track-plan-file plan.md
) > "$TEST_DIR/setup-output.txt" 2>&1
SETUP_EXIT=$?

TRACKER_FILE=$(find "$PLAN_REPO/.loop" -name 'goal-tracker.md' -type f 2>/dev/null | head -1)
if [[ -n "$SETUP_DEPS_MISSING" && "$SETUP_EXIT" -ne 0 ]]; then
    # setup-rlcr-loop.sh refuses to run without its own prerequisites, which is
    # a different check than this one. CI has them; a hand-stripped PATH may not.
    skip "plan Goal and Acceptance Criteria extraction" \
        "setup-rlcr-loop.sh prerequisites missing: $SETUP_DEPS_MISSING"
elif [[ "$SETUP_EXIT" -eq 0 && -n "$TRACKER_FILE" ]]; then
    pass "setup-rlcr-loop.sh generated a goal tracker"
    TRACKER_TEXT="$(cat "$TRACKER_FILE")"

    if [[ "$TRACKER_TEXT" == *"Carry the goal sentence into the generated tracker."* ]]; then
        pass "plan Goal section reaches the goal tracker"
    else
        fail "plan Goal extraction" "the goal sentence" "$TRACKER_TEXT"
    fi

    if [[ "$TRACKER_TEXT" == *"Carry the acceptance sentence into the generated tracker."* ]]; then
        pass "plan Acceptance Criteria section reaches the goal tracker"
    else
        fail "plan Acceptance Criteria extraction" "the acceptance sentence" "$TRACKER_TEXT"
    fi
else
    fail "setup-rlcr-loop.sh run" "exit 0 and a goal-tracker.md" \
        "exit $SETUP_EXIT, tracker [$TRACKER_FILE], $(cat "$TEST_DIR/setup-output.txt")"
fi

print_test_summary "Runtime Portability Test Summary"
