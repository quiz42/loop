#!/usr/bin/env bash
#
# Run all test suites for the Loop plugin (parallel execution)
#
# Usage: ./tests/run-all-tests.sh
#        LOOP_TEST_RUNNER_CHECK_ONLY=1 ./tests/run-all-tests.sh
#            Resolve the interpreter, report which Bash would run the suites,
#            and exit without running them. Used by CI logs and by
#            tests/test-runner-portability.sh.
#
# Each test suite runs in its own isolated temp directory, so parallel
# execution is safe with no shared state or resource contention.
#
# Requires Bash >= 4.0 (associative arrays). macOS ships Bash 3.2, so on macOS
# install a newer Bash (`brew install bash`); CI provisions it explicitly. When
# started under an older Bash this script re-execs into a newer one if the
# machine has it and otherwise fails with exit 1 -- it must never degrade
# silently, because a partial run that exits 0 reads as a green test run.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed, or the runner could not run at all
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Minimum Bash major version this runner needs.
LOOP_RUNNER_MIN_BASH_MAJOR=4

print_bash_requirement() {
    echo "tests/run-all-tests.sh requires Bash >= ${LOOP_RUNNER_MIN_BASH_MAJOR}.0;" \
         "no tests were run."
    echo ""
    echo "macOS ships Bash 3.2. Install a current Bash and re-run:"
    echo "  brew install bash"
    echo "  \"\$(brew --prefix)/bin/bash\" tests/run-all-tests.sh"
}

# Re-exec into a Bash >= 4 if the current one is too old, or fail loudly.
require_modern_bash() {
    local major="${BASH_VERSINFO[0]:-0}"
    if [[ "$major" -ge "$LOOP_RUNNER_MIN_BASH_MAJOR" ]]; then
        return 0
    fi

    if [[ -n "${LOOP_TEST_RUNNER_REEXEC:-}" ]]; then
        echo "Error: re-exec did not reach a newer Bash (still Bash ${BASH_VERSION:-unknown})." >&2
        print_bash_requirement >&2
        exit 1
    fi

    local candidates=()
    if command -v brew >/dev/null 2>&1; then
        local brew_prefix
        brew_prefix="$(brew --prefix 2>/dev/null || echo "")"
        [[ -n "$brew_prefix" ]] && candidates+=("$brew_prefix/bin/bash")
    fi
    candidates+=("/opt/homebrew/bin/bash" "/usr/local/bin/bash")
    local path_bash
    path_bash="$(command -v bash 2>/dev/null || echo "")"
    [[ -n "$path_bash" ]] && candidates+=("$path_bash")

    local candidate candidate_major
    for candidate in "${candidates[@]}"; do
        [[ -x "$candidate" ]] || continue
        candidate_major="$("$candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
        [[ "$candidate_major" =~ ^[0-9]+$ ]] || continue
        [[ "$candidate_major" -ge "$LOOP_RUNNER_MIN_BASH_MAJOR" ]] || continue

        echo "Note: Bash ${BASH_VERSION:-unknown} is older than ${LOOP_RUNNER_MIN_BASH_MAJOR}.0;" \
             "re-executing under $candidate."
        export LOOP_TEST_RUNNER_REEXEC=1
        exec "$candidate" "$SCRIPT_PATH" "$@"
    done

    {
        echo "Error: this is Bash ${BASH_VERSION:-unknown} and no newer Bash was found."
        print_bash_requirement
    } >&2
    exit 1
}

require_modern_bash "$@"

# shellcheck source=tests/portable-helpers.sh
source "$SCRIPT_DIR/portable-helpers.sh"

if [[ -n "${LOOP_TEST_RUNNER_CHECK_ONLY:-}" ]]; then
    echo "Interpreter: Bash ${BASH_VERSION} (${BASH:-unknown})"
    echo "Millisecond timestamp source: ${LOOP_PORTABLE_MS_MODE}"
    echo "Runner prerequisites satisfied; no suites were run (check-only mode)."
    exit 0
fi

# Max parallel test jobs (throttle to avoid resource exhaustion in small CI runners).
# Override with LOOP_TEST_JOBS=<N>.
default_jobs() {
    local n=4
    if command -v getconf >/dev/null 2>&1; then
        n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=4
    # Cap by default to keep memory/process usage bounded.
    [[ "$n" -gt 8 ]] && n=8
    [[ "$n" -lt 1 ]] && n=1
    echo "$n"
}

MAX_JOBS="${LOOP_TEST_JOBS:-$(default_jobs)}"
if ! [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] || [[ "$MAX_JOBS" -lt 1 ]]; then
    echo "Error: LOOP_TEST_JOBS must be an integer >= 1, got: ${LOOP_TEST_JOBS:-}" >&2
    exit 1
fi

# wait -n is available starting from bash 4.3
supports_wait_n() {
    local major="${BASH_VERSINFO[0]:-0}"
    local minor="${BASH_VERSINFO[1]:-0}"
    [[ "$major" -gt 4 ]] || ( [[ "$major" -eq 4 ]] && [[ "$minor" -ge 3 ]] )
}

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo "========================================"
echo "Running All Loop Plugin Tests"
echo "========================================"
echo "Parallel jobs: $MAX_JOBS"
echo ""

# Test suites to run
TEST_SUITES=(
    "test-template-loader.sh"
    "test-bash-validator-patterns.sh"
    "test-todo-checker.sh"
    "test-plan-file-validation.sh"
    "test-template-references.sh"
    "test-state-exit-naming.sh"
    "test-stop-gate.sh"
    "test-templates-comprehensive.sh"
    "test-plan-file-hooks.sh"
    "test-stop-hook-legacy-compat.sh"
    "test-stop-hook-bg-allow.sh"
    "test-error-scenarios.sh"
    "test-ansi-parsing.sh"
    "test-allowlist-validators.sh"
    "test-finalize-phase.sh"
    "test-codex-review-merge.sh"
    "test-cancel-signal-file.sh"
    "test-loop-escape.sh"
    "test-zsh-monitor-safety.sh"
    "test-monitor-runtime.sh"
    "test-monitor-e2e-deletion.sh"
    "test-monitor-e2e-sigint.sh"
    "test-gen-plan.sh"
    "test-refine-plan.sh"
    "test-task-tag-routing.sh"
    "test-config-merge.sh"
    "test-config-error-handling.sh"
    "test-codex-hook-install.sh"
    "test-unified-codex-config.sh"
    "test-disable-nested-codex-hooks.sh"
    # Session ID and Agent Teams tests
    "test-session-id.sh"
    "test-agent-teams.sh"
    # Ask Codex tests
    "test-ask-codex.sh"
    # Bitlesson routing tests
    "test-bitlesson-select-routing.sh"
    # Provider routing tests
    "test-model-router.sh"
    # Skill monitor tests
    "test-skill-monitor.sh"
    # Cross-platform portability of the runner and its shared helpers
    "test-runner-portability.sh"
    # Proof contract vectors
    "test-proof-contract.sh"
    "test-proof-export.sh"
    "test-proof-verify.sh"
    # Robustness tests
    "robustness/test-state-file-robustness.sh"
    "robustness/test-session-robustness.sh"
    "robustness/test-goal-tracker-robustness.sh"
    "robustness/test-path-validation-robustness.sh"
    "robustness/test-git-operations-robustness.sh"
    "robustness/test-hook-input-robustness.sh"
    "robustness/test-template-stress-robustness.sh"
    "robustness/test-plan-file-robustness.sh"
    "robustness/test-cancel-security-robustness.sh"
    "robustness/test-timeout-robustness.sh"
    "robustness/test-base-branch-detection.sh"
    "robustness/test-setup-scripts-robustness.sh"
    "robustness/test-concurrent-state-robustness.sh"
    "robustness/test-hook-system-robustness.sh"
    "robustness/test-template-error-robustness.sh"
    "robustness/test-state-transition-robustness.sh"
)

# Tests that must be run with zsh (not bash)
ZSH_TESTS=(
    "test-zsh-monitor-safety.sh"
)

# Temp directory for per-suite output files
OUTPUT_DIR=$(mktemp -d)

# Set to 1 only once the summary has been printed. Any earlier exit -- an
# aborted loop, an arithmetic error, an unbound variable -- must surface as a
# failure instead of the exit 0 an incomplete run used to produce.
RUNNER_REPORTED=0

runner_exit_trap() {
    local status=$?
    rm -rf "$OUTPUT_DIR"
    if [[ "$RUNNER_REPORTED" -ne 1 ]]; then
        echo "" >&2
        echo "Error: run-all-tests.sh aborted before printing its summary (exit status $status)." >&2
        echo "No test results were produced; reporting this as a failure." >&2
        exit 1
    fi
    exit "$status"
}
trap runner_exit_trap EXIT

# Provide a mock codex binary when the real one is not installed.
# Tests only need codex to pass the `command -v codex` check in setup scripts;
# tests that require specific codex behavior already create their own mocks.
if ! command -v codex &>/dev/null; then
    mkdir -p "$OUTPUT_DIR/mock-bin"
    cat > "$OUTPUT_DIR/mock-bin/codex" << 'MOCK_CODEX'
#!/usr/bin/env bash
exit 0
MOCK_CODEX
    chmod +x "$OUTPUT_DIR/mock-bin/codex"
    export PATH="$OUTPUT_DIR/mock-bin:$PATH"
fi

# Check if a suite needs zsh
needs_zsh() {
    local suite="$1"
    for zsh_test in "${ZSH_TESTS[@]}"; do
        if [[ "$suite" == "$zsh_test" ]]; then
            return 0
        fi
    done
    return 1
}

# Launch all test suites in parallel
declare -A PIDS          # suite -> PID
declare -A SKIPPED       # suite -> reason
ACTIVE_PIDS=()

for suite in "${TEST_SUITES[@]}"; do
    suite_path="$SCRIPT_DIR/$suite"
    safe_name="$(echo "$suite" | tr '/' '_')"
    out_file="$OUTPUT_DIR/${safe_name}.out"
    exit_file="$OUTPUT_DIR/${safe_name}.exit"
    time_file="$OUTPUT_DIR/${safe_name}.time"

    if [[ ! -f "$suite_path" ]]; then
        SKIPPED["$suite"]="not found"
        continue
    fi

    if needs_zsh "$suite"; then
        if ! command -v zsh &>/dev/null; then
            SKIPPED["$suite"]="zsh not available"
            continue
        fi
        (
            t_start=$(portable_epoch_ms)
            zsh "$suite_path" >"$out_file" 2>&1
            echo $? >"$exit_file"
            echo $(( $(portable_epoch_ms) - t_start )) >"$time_file"
        ) &
    else
        (
            t_start=$(portable_epoch_ms)
            "$suite_path" >"$out_file" 2>&1
            echo $? >"$exit_file"
            echo $(( $(portable_epoch_ms) - t_start )) >"$time_file"
        ) &
    fi
    PIDS["$suite"]=$!
    ACTIVE_PIDS+=("${PIDS[$suite]}")

    # Throttle background jobs
    while [[ "${#ACTIVE_PIDS[@]}" -ge "$MAX_JOBS" ]]; do
        if supports_wait_n; then
            wait -n 2>/dev/null || true
            # Prune finished PIDs from ACTIVE_PIDS
            still_running=()
            for pid in "${ACTIVE_PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    still_running+=("$pid")
                fi
            done
            ACTIVE_PIDS=("${still_running[@]}")
        else
            # Fallback: wait for the oldest PID (less efficient but portable in older bash)
            wait "${ACTIVE_PIDS[0]}" 2>/dev/null || true
            ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
        fi
    done
done

# Wait for all and collect results
TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_SUITES=()
# Sortable file: elapsed_ms<TAB>display_line
SORT_FILE="$OUTPUT_DIR/sortable.txt"
: > "$SORT_FILE"

for suite in "${TEST_SUITES[@]}"; do
    [[ -n "${SKIPPED[$suite]+x}" ]] && continue

    pid="${PIDS[$suite]}"
    wait "$pid" 2>/dev/null

    safe_name="$(echo "$suite" | tr '/' '_')"
    out_file="$OUTPUT_DIR/${safe_name}.out"
    exit_file="$OUTPUT_DIR/${safe_name}.exit"
    time_file="$OUTPUT_DIR/${safe_name}.time"

    exit_code=$(cat "$exit_file" 2>/dev/null || echo "1")
    output=$(cat "$out_file" 2>/dev/null || echo "")
    elapsed_ms=$(cat "$time_file" 2>/dev/null || echo "0")
    # A suite killed before it wrote its timing file must not break printf '%d'.
    case "$elapsed_ms" in
        '' | *[!0-9]*) elapsed_ms=0 ;;
    esac
    elapsed_display=$(portable_format_ms "$elapsed_ms")

    # Strip ANSI escape codes and extract pass/fail counts
    output_stripped=$(printf '%s\n' "$output" | portable_strip_ansi)
    passed=$(echo "$output_stripped" | grep -oE 'Passed:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | tail -1 || echo "0")
    failed=$(echo "$output_stripped" | grep -oE 'Failed:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | tail -1 || echo "0")

    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))

    if [[ $exit_code -ne 0 ]] || [[ "$failed" -gt 0 ]]; then
        FAILED_SUITES+=("$suite")
        line=$(echo -e "${RED}FAILED${NC}: $suite (exit code: $exit_code, failed: $failed, ${elapsed_display})")
        printf '%d\t%s\n' "$elapsed_ms" "$line" >> "$SORT_FILE"
        # Preserve the full suite log so CI surfaces the exact failing assertion.
        printf '%s\n' "$output" > "$OUTPUT_DIR/${safe_name}.detail"
    else
        zsh_label=""
        needs_zsh "$suite" && zsh_label=" (zsh)"
        line=$(echo -e "${GREEN}PASSED${NC}: $suite${zsh_label} ($passed tests, ${elapsed_display})")
        printf '%d\t%s\n' "$elapsed_ms" "$line" >> "$SORT_FILE"
    fi
done

# Print skipped suites first
for suite in "${TEST_SUITES[@]}"; do
    if [[ -n "${SKIPPED[$suite]+x}" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $suite (${SKIPPED[$suite]})"
    fi
done

# Print results sorted by elapsed time (fastest first)
sort -t$'\t' -k1,1n "$SORT_FILE" | cut -f2-

echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Total Passed: ${GREEN}$TOTAL_PASSED${NC}"
echo -e "Total Failed: ${RED}$TOTAL_FAILED${NC}"
echo ""

# The summary is on screen, so the exit status below is a real verdict.
RUNNER_REPORTED=1

if [[ ${#FAILED_SUITES[@]} -gt 0 ]]; then
    echo -e "${RED}Failed Test Suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo "  - $suite"
        safe_name="$(echo "$suite" | tr '/' '_')"
        detail_file="$OUTPUT_DIR/${safe_name}.detail"
        if [[ -f "$detail_file" ]]; then
            echo "    ----------------------------------------"
            sed 's/^/    /' "$detail_file"
            echo ""
        fi
    done
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
