#!/usr/bin/env bash
#
# Common functions for RLCR loop hooks
#
# This library provides shared functionality used by:
# - loop-read-validator.sh
# - loop-write-validator.sh
# - loop-edit-validator.sh
# - loop-bash-validator.sh
# - loop-plan-file-validator.sh
# - loop-codex-stop-hook.sh
# - setup-rlcr-loop.sh
# - cancel-rlcr-loop.sh
#

# Source guard: prevent double-sourcing (readonly vars would fail)
[[ -n "${_LOOP_COMMON_LOADED:-}" ]] && return 0 2>/dev/null || true
_LOOP_COMMON_LOADED=1

# ========================================
# Constants
# ========================================

# State file field names
readonly FIELD_PLAN_TRACKED="plan_tracked"
readonly FIELD_START_BRANCH="start_branch"
readonly FIELD_BASE_BRANCH="base_branch"
readonly FIELD_BASE_COMMIT="base_commit"
readonly FIELD_PLAN_FILE="plan_file"
readonly FIELD_CURRENT_ROUND="current_round"
readonly FIELD_MAX_ITERATIONS="max_iterations"
readonly FIELD_PUSH_EVERY_ROUND="push_every_round"
readonly FIELD_CODEX_MODEL="codex_model"
readonly FIELD_CODEX_EFFORT="codex_effort"
readonly FIELD_CODEX_TIMEOUT="codex_timeout"
readonly FIELD_REVIEW_STARTED="review_started"
readonly FIELD_FULL_REVIEW_ROUND="full_review_round"
readonly FIELD_ASK_CODEX_QUESTION="ask_codex_question"
readonly FIELD_SESSION_ID="session_id"
readonly FIELD_AGENT_TEAMS="agent_teams"
readonly FIELD_PRIVACY_MODE="privacy_mode"
readonly FIELD_MAINLINE_STALL_COUNT="mainline_stall_count"
readonly FIELD_LAST_MAINLINE_VERDICT="last_mainline_verdict"
readonly FIELD_DRIFT_STATUS="drift_status"
readonly FIELD_REVIEWED_COMMIT="reviewed_commit"
readonly FIELD_REVIEWED_AT="reviewed_at"
readonly FIELD_REVIEWED_BASE="reviewed_base"
readonly FIELD_HEAD_COMMIT="head_commit"
readonly FIELD_ENDED_AT="ended_at"

readonly MAINLINE_VERDICT_ADVANCED="advanced"
readonly MAINLINE_VERDICT_STALLED="stalled"
readonly MAINLINE_VERDICT_REGRESSED="regressed"
readonly MAINLINE_VERDICT_UNKNOWN="unknown"

readonly DRIFT_STATUS_NORMAL="normal"
readonly DRIFT_STATUS_REPLAN_REQUIRED="replan_required"

# Default Codex configuration (single source of truth - all scripts reference this)
# Scripts can pre-set DEFAULT_CODEX_MODEL/DEFAULT_CODEX_EFFORT before sourcing to override.
# Config-backed defaults are loaded from the merge hierarchy after config-loader.sh is sourced.
# Precedence: pre-set value > config value > hardcoded fallback (gpt-5.5/high)
#
# The actual assignment happens in the "Config-backed defaults" section below,
# after config-loader.sh has been sourced and merged config is available.

# Codex review markers
readonly MARKER_COMPLETE="COMPLETE"
readonly MARKER_STOP="STOP"

# Exit reasons (used with end_loop function)
# complete   - Codex confirmed all goals achieved (normal success)
# cancel     - User cancelled with /cancel-rlcr-loop
# maxiter    - Reached maximum iterations limit
# stop       - Codex triggered circuit breaker (stagnation detected)
# unexpected - System error or invalid state (e.g., corrupted state file)
readonly EXIT_COMPLETE="complete"
readonly EXIT_CANCEL="cancel"
readonly EXIT_MAXITER="maxiter"
readonly EXIT_STOP="stop"
readonly EXIT_UNEXPECTED="unexpected"

# ========================================
# JSON Input Validation
# ========================================

# Validate JSON input and extract tool_name
# Usage: validate_hook_input "$json_input"
# Returns: 0 if valid JSON with tool_name, 1 if invalid
# Sets: VALIDATED_TOOL_NAME, VALIDATED_TOOL_INPUT
#
# Non-UTF8 handling behavior:
# - Null bytes (0x00): Rejected with exit 1
# - Invalid UTF-8 sequences (0x80-0xFF outside valid UTF-8): Rejected by jq as invalid JSON
# - Valid UTF-8 non-ASCII characters: Accepted (jq handles Unicode correctly)
validate_hook_input() {
    local input="$1"

    # Reject null bytes (security) - portable check without grep -P (BSD incompatible)
    # tr -cd '\0' keeps only null bytes, wc -c counts them
    if [[ $(printf '%s' "$input" | tr -cd '\0' | wc -c) -gt 0 ]]; then
        echo "Error: Input contains null bytes" >&2
        return 1
    fi

    # Reject non-UTF8 bytes (security/consistency)
    # Check for bytes in 0x80-0xFF that are NOT part of valid UTF-8 sequences
    # Skip if iconv is not available (common in minimal containers like Alpine)
    if command -v iconv >/dev/null 2>&1; then
        if ! printf '%s' "$input" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
            echo "Error: Input contains invalid UTF-8 sequences" >&2
            return 1
        fi
    fi

    # Validate JSON syntax with jq
    if ! printf '%s' "$input" | jq -e '.' >/dev/null 2>&1; then
        echo "Error: Invalid JSON syntax" >&2
        return 1
    fi

    # Extract tool_name (required)
    VALIDATED_TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty')
    if [[ -z "$VALIDATED_TOOL_NAME" ]]; then
        echo "Error: Missing required field: tool_name" >&2
        return 1
    fi

    # Extract tool_input (required for Read/Write/Bash)
    VALIDATED_TOOL_INPUT=$(printf '%s' "$input" | jq -r '.tool_input // empty')

    return 0
}

# Validate that a specific field exists in tool_input
# Usage: require_tool_input_field "$json_input" "field_name"
# Returns: 0 if field exists and is non-empty, 1 otherwise
require_tool_input_field() {
    local input="$1"
    local field="$2"

    local value
    value=$(printf '%s' "$input" | jq -r ".tool_input.$field // empty")

    if [[ -z "$value" ]]; then
        echo "Error: Missing required field: tool_input.$field" >&2
        return 1
    fi

    return 0
}

# Check if JSON is deeply nested (potential DoS)
# Usage: is_deeply_nested "$json_input" [max_depth]
# Returns: 0 if too deeply nested, 1 otherwise
is_deeply_nested() {
    local input="$1"
    local max_depth="${2:-30}"

    # Use jq to check depth - getpath on recursive descent gives us depth
    local actual_depth
    actual_depth=$(printf '%s' "$input" | jq '[paths | length] | max // 0' 2>/dev/null || echo "0")

    if [[ "$actual_depth" -gt "$max_depth" ]]; then
        echo "Error: JSON structure exceeds maximum depth of $max_depth (actual: $actual_depth)" >&2
        return 0
    fi

    return 1
}

# ========================================
# Library Setup
# ========================================

# Source template loader
LOOP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOOP_COMMON_PLUGIN_ROOT="$(cd "$LOOP_COMMON_DIR/../.." && pwd)"
export PLUGIN_ROOT="${PLUGIN_ROOT:-$LOOP_COMMON_PLUGIN_ROOT}"

# Shared project-root resolver (CLAUDE_PROJECT_DIR -> git toplevel,
# realpath-canonicalized). Must load before any caller needs PROJECT_ROOT.
source "$LOOP_COMMON_DIR/project-root.sh"

# Portable timeout wrapper (run_with_timeout) for git/CLI subprocess calls.
# Sourced here unconditionally so every loop-common.sh caller gets it for
# free, instead of each caller needing its own `source portable-timeout.sh`.
source "$LOOP_COMMON_PLUGIN_ROOT/scripts/portable-timeout.sh"

# Default timeout for git operations; callers may override before sourcing.
GIT_TIMEOUT="${GIT_TIMEOUT:-30}"

_lc_errexit=false; [[ -o errexit ]] && _lc_errexit=true
_lc_nounset=false; [[ -o nounset ]] && _lc_nounset=true
_lc_pipefail=false; [[ -o pipefail ]] && _lc_pipefail=true
source "$LOOP_COMMON_PLUGIN_ROOT/scripts/lib/config-loader.sh"
$_lc_errexit && set -e || set +e
$_lc_nounset && set -u || set +u
$_lc_pipefail && set -o pipefail || set +o pipefail
unset _lc_errexit _lc_nounset _lc_pipefail

_LOOP_COMMON_PROJECT_ROOT="$(resolve_project_root 2>/dev/null || true)"
# Config loading is best-effort: use || true so a config-load failure does not
# abort sourcing before callers' dependency checks (jq, codex) are reached.
# Stderr is NOT suppressed so malformed config warnings remain visible.
#
# Skip config loading when no project root is available (e.g. loop.sh is
# sourced from .bashrc/.zshrc in a non-repo directory like $HOME). Passing an
# empty project_root to load_merged_config would surface a usage error on
# stderr every time the shell starts.
if [[ -n "$_LOOP_COMMON_PROJECT_ROOT" ]]; then
    _LOOP_COMMON_CONFIG="$(load_merged_config "$LOOP_COMMON_PLUGIN_ROOT" "$_LOOP_COMMON_PROJECT_ROOT")" || true
else
    _LOOP_COMMON_CONFIG=""
fi

# Load bitlesson model from merged config (controls which CLI bitlesson-select.sh uses)
DEFAULT_BITLESSON_MODEL="$(get_config_value "$_LOOP_COMMON_CONFIG" "bitlesson_model" 2>/dev/null || true)"
DEFAULT_BITLESSON_MODEL="${DEFAULT_BITLESSON_MODEL:-haiku}"

# Load codex model/effort from merged config so .loop/config.json can set persistent
# defaults for all Codex-using features (RLCR, ask-codex).
# Precedence: pre-set by caller > config value > hardcoded fallback (gpt-5.5/high)
_cfg_codex_model="$(get_config_value "$_LOOP_COMMON_CONFIG" "codex_model" 2>/dev/null || true)"
if [[ -n "$_cfg_codex_model" && ! "$_cfg_codex_model" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Warning: Invalid codex_model in merged config: $_cfg_codex_model" >&2
    echo "  Ignoring configured codex_model; using caller preset or fallback" >&2
    _cfg_codex_model=""
elif [[ -n "$_cfg_codex_model" && ! "$_cfg_codex_model" =~ ^(gpt-|o[0-9]) ]]; then
    echo "Warning: Unsupported codex_model in merged config: $_cfg_codex_model" >&2
    echo "  Must start with a Codex model prefix: gpt- or o[0-9]" >&2
    echo "  Ignoring configured codex_model; using caller preset or fallback" >&2
    _cfg_codex_model=""
fi
DEFAULT_CODEX_MODEL="${DEFAULT_CODEX_MODEL:-${_cfg_codex_model:-gpt-5.5}}"
_cfg_codex_effort="$(get_config_value "$_LOOP_COMMON_CONFIG" "codex_effort" 2>/dev/null || true)"
if [[ -n "$_cfg_codex_effort" && ! "$_cfg_codex_effort" =~ ^(xhigh|high|medium|low)$ ]]; then
    echo "Warning: Invalid codex_effort in merged config: $_cfg_codex_effort" >&2
    echo "  Must be one of: xhigh, high, medium, low" >&2
    echo "  Ignoring configured codex_effort; using caller preset or fallback" >&2
    _cfg_codex_effort=""
fi
DEFAULT_CODEX_EFFORT="${DEFAULT_CODEX_EFFORT:-${_cfg_codex_effort:-high}}"

# Load agent_teams from merged config (controls whether RLCR uses agent teams by default)
# Precedence: pre-set by caller (e.g. --agent-teams flag) > config value > hardcoded fallback (false)
_cfg_agent_teams="$(get_config_value "$_LOOP_COMMON_CONFIG" "agent_teams" 2>/dev/null || true)"
DEFAULT_AGENT_TEAMS="${DEFAULT_AGENT_TEAMS:-${_cfg_agent_teams:-false}}"
unset _cfg_codex_model _cfg_codex_effort _cfg_agent_teams

unset _LOOP_COMMON_PROJECT_ROOT _LOOP_COMMON_CONFIG

source "$LOOP_COMMON_DIR/template-loader.sh"

# Initialize template directory (can be overridden by sourcing script)
TEMPLATE_DIR="${TEMPLATE_DIR:-$(get_template_dir "$LOOP_COMMON_DIR")}"

# Validate template directory exists (warn but don't fail - allows graceful degradation)
if ! validate_template_dir "$TEMPLATE_DIR" 2>/dev/null; then
    echo "Warning: Template directory validation failed. Using inline fallbacks." >&2
fi

# Extract session_id from hook JSON input
# Usage: extract_session_id "$json_input"
# Outputs the session_id to stdout, or empty string if not available
extract_session_id() {
    local input="$1"
    printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || echo ""
}

# Persist a Claude session_id into a state file's frontmatter, but only when
# the field is currently empty. Idempotent and safe under `set -euo pipefail`.
#
# This is the backfill safety net for the PostToolUse recorder
# (loop-post-bash-hook.sh): the Stop hook always has the authoritative
# session_id, so calling this each round guarantees completed loops
# (complete-state.md) retain a resolvable session id even if the one-shot
# PostToolUse signal was never consumed.
#
# Usage: persist_session_id_if_empty "$state_file" "$session_id"
# Returns 0 in all no-op and success cases.
persist_session_id_if_empty() {
    local state_file="$1"
    local session_id="$2"

    [[ -z "$state_file" || ! -f "$state_file" ]] && return 0
    [[ -z "$session_id" ]] && return 0

    # Read the current value using the same portable frontmatter-body + grep
    # extraction used elsewhere (avoids BSD-sed nested-block incompatibility).
    local current
    current=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null | grep "^${FIELD_SESSION_ID}:" | sed "s/^${FIELD_SESSION_ID}: *//" | tr -d ' ' || true)
    [[ -n "$current" ]] && return 0

    # Replace the empty field line only (safe awk handles special chars in id).
    local temp_file="${state_file}.tmp.$$"
    awk -v new_id="$session_id" -v field="${FIELD_SESSION_ID}" '
        $0 ~ "^" field ":[[:space:]]*$" {
            print field ": " new_id
            next
        }
        { print }
    ' "$state_file" > "$temp_file" && mv "$temp_file" "$state_file"
}

# Background-task helpers (expand_leading_tilde, extract_transcript_path,
# derive_loop_start_iso_ts, list/has/count_pending_background_task[_ids],
# handle_bg_task_short_circuit) live in loop-bg-tasks.sh and are sourced
# at the bottom of this file so every existing consumer of loop-common.sh
# continues to get them transparently.

# Resolve the active state file for a loop directory
# Checks for finalize-state.md first, then state.md
# Usage: resolve_active_state_file "$loop_dir"
# Outputs the state file path to stdout, or empty string if none found
resolve_active_state_file() {
    local loop_dir="$1"

    if [[ -f "$loop_dir/methodology-analysis-state.md" ]]; then
        echo "$loop_dir/methodology-analysis-state.md"
    elif [[ -f "$loop_dir/finalize-state.md" ]]; then
        echo "$loop_dir/finalize-state.md"
    elif [[ -f "$loop_dir/state.md" ]]; then
        echo "$loop_dir/state.md"
    else
        echo ""
    fi
}

# Resolve any state file in a loop directory (active or terminal)
# Checks active states first (state.md, finalize-state.md), then falls back
# to any terminal state file (*-state.md such as complete-state.md, cancel-state.md).
# Usage: resolve_any_state_file "$loop_dir"
# Outputs the state file path to stdout, or empty string if none found
resolve_any_state_file() {
    local loop_dir="$1"

    # Prefer active states
    if [[ -f "$loop_dir/methodology-analysis-state.md" ]]; then
        echo "$loop_dir/methodology-analysis-state.md"
        return
    elif [[ -f "$loop_dir/finalize-state.md" ]]; then
        echo "$loop_dir/finalize-state.md"
        return
    elif [[ -f "$loop_dir/state.md" ]]; then
        echo "$loop_dir/state.md"
        return
    fi

    # Fall back to any terminal state file
    local terminal_state
    terminal_state=$(ls -1 "$loop_dir"/*-state.md 2>/dev/null | head -1)
    echo "${terminal_state:-}"
}

# Find the most recent active loop directory matching optional session_id filter
#
# Without session_id filter: only checks the single newest directory.
#   If it has state.md or finalize-state.md, returns it; otherwise returns empty.
#   This preserves zombie-loop protection: older directories are never examined,
#   so a stale state.md in an older directory cannot be accidentally revived.
#
# With session_id filter: finds the newest directory belonging to that session
#   (matching ANY *state.md file including terminal states), then checks whether
#   it is still active. If the session's newest directory is in terminal state
#   (complete-state.md, cancel-state.md, etc.), returns empty immediately --
#   preventing stale older loops from being revived. This enables multiple
#   concurrent RLCR loops with different session IDs in the same project.
#
# Empty stored session_id matches any filter (backward compat for pre-session
# state files).
#
# Third parameter `allow_bg_marker_fallback` (default "false"): when "true",
# the session-filter branch also considers a mismatched-session dir that holds
# a `bg-pending.marker` file AND an active state file. Only the RLCR stop
# hook opts in to this; every other caller (read/write/bash/plan-file
# validators, ...) keeps strict session isolation.
#
# Outputs the directory path to stdout, or empty string if none found
find_active_loop() {
    local loop_base_dir="$1"
    local filter_session_id="${2:-}"
    local allow_bg_marker_fallback="${3:-false}"

    if [[ ! -d "$loop_base_dir" ]]; then
        echo ""
        return
    fi

    if [[ -z "$filter_session_id" ]]; then
        # No filter: only check the single newest directory (zombie-loop protection)
        local newest_dir
        newest_dir=$(ls -1d "$loop_base_dir"/*/ 2>/dev/null | sort -r | head -1)

        if [[ -n "$newest_dir" ]]; then
            local state_file
            state_file=$(resolve_active_state_file "${newest_dir%/}")
            if [[ -n "$state_file" ]]; then
                echo "${newest_dir%/}"
                return
            fi
        fi
        echo ""
        return
    fi

    # Session filter: iterate newest-to-oldest.
    #
    # The caller's own (exact stored session_id) match takes precedence over
    # any marker-based adoption: with multiple active RLCR loops in the same
    # repo, a newer dir parked by a different session must not be returned
    # before an older dir that actually belongs to the caller. Marker
    # candidates are recorded during the scan and only used as a fallback
    # when no exact match is found anywhere. Zombie-loop protection
    # (terminal newest for this session returns empty) still wins over
    # marker fallback.
    local dir
    local marker_candidate=""
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local trimmed_dir="${dir%/}"

        local any_state
        any_state=$(resolve_any_state_file "$trimmed_dir")
        if [[ -z "$any_state" ]]; then
            continue
        fi

        local stored_session_id
        # NOTE: extract via frontmatter-body + grep rather than a nested sed
        # block ({ /re/{ s//; p } }). BSD/macOS sed rejects that one-liner with
        # "extra characters at the end of } command" and exits non-zero, which
        # under `set -euo pipefail` silently kills the hook.
        stored_session_id=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$any_state" 2>/dev/null | grep "^${FIELD_SESSION_ID}:" | sed "s/^${FIELD_SESSION_ID}: *//" | tr -d ' ' || true)

        # Empty stored session_id matches any session (backward compat).
        if [[ -z "$stored_session_id" ]] || [[ "$stored_session_id" == "$filter_session_id" ]]; then
            # Newest dir for this session -- only return if active.
            local active_state
            active_state=$(resolve_active_state_file "$trimmed_dir")
            if [[ -n "$active_state" ]]; then
                echo "$trimmed_dir"
                return
            fi
            # Session's newest loop is in terminal state; do not fall through
            # to marker-based adoption either.
            echo ""
            return
        fi

        # Session mismatch. Only the stop hook opts in to marker-based
        # adoption; validators and other callers keep strict isolation, so
        # the candidate is only recorded when the caller explicitly allows
        # it.
        if [[ "$allow_bg_marker_fallback" == "true" ]] \
           && [[ -z "$marker_candidate" ]] \
           && [[ -f "$trimmed_dir/bg-pending.marker" ]]; then
            local candidate_state
            candidate_state=$(resolve_active_state_file "$trimmed_dir")
            if [[ -n "$candidate_state" ]]; then
                marker_candidate="$trimmed_dir"
            fi
            # Marker on a terminal loop is stale; leave it alone.
        fi
    done < <(ls -1d "$loop_base_dir"/*/ 2>/dev/null | sort -r)

    # No exact session match. Fall back to marker-based adoption only when
    # the caller explicitly opted in -- the stop hook uses this to surface
    # a "parked by another session" notice or to resume its own parked
    # loop after a previous session died before the bg completion arrived.
    if [[ "$allow_bg_marker_fallback" == "true" ]] && [[ -n "$marker_candidate" ]]; then
        echo "$marker_candidate"
        return
    fi

    echo ""
}

# Extract current round number from state.md
# Outputs the round number to stdout, defaults to 0
# Note: For full state parsing, use parse_state_file() instead
get_current_round() {
    local state_file="$1"

    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    local current_round
    current_round=$(echo "$frontmatter" | grep "^${FIELD_CURRENT_ROUND}:" | sed "s/${FIELD_CURRENT_ROUND}: *//" | tr -d ' ')

    echo "${current_round:-0}"
}

# Extract state fields from frontmatter content (internal helper)
# Usage: _parse_state_fields
# Requires STATE_FRONTMATTER to be set before calling
# Sets all STATE_* field variables without applying defaults
_parse_state_fields() {
    # Parse fields with consistent quote handling
    # Legacy quote-stripping kept for backward compatibility with older state files
    STATE_PLAN_TRACKED=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PLAN_TRACKED}:" | sed "s/${FIELD_PLAN_TRACKED}: *//" | tr -d ' ' || true)
    STATE_START_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_START_BRANCH}:" | sed "s/${FIELD_START_BRANCH}: *//; s/^\"//; s/\"\$//" || true)
    STATE_BASE_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_BASE_BRANCH}:" | sed "s/${FIELD_BASE_BRANCH}: *//; s/^\"//; s/\"\$//" || true)
    STATE_BASE_COMMIT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_BASE_COMMIT}:" | sed "s/${FIELD_BASE_COMMIT}: *//; s/^\"//; s/\"\$//" || true)
    STATE_PLAN_FILE=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PLAN_FILE}:" | sed "s/${FIELD_PLAN_FILE}: *//; s/^\"//; s/\"\$//" || true)
    STATE_CURRENT_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CURRENT_ROUND}:" | sed "s/${FIELD_CURRENT_ROUND}: *//" | tr -d ' ' || true)
    STATE_MAX_ITERATIONS=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_MAX_ITERATIONS}:" | sed "s/${FIELD_MAX_ITERATIONS}: *//" | tr -d ' ' || true)
    STATE_PUSH_EVERY_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PUSH_EVERY_ROUND}:" | sed "s/${FIELD_PUSH_EVERY_ROUND}: *//" | tr -d ' ' || true)
    STATE_CODEX_MODEL=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_MODEL}:" | sed "s/${FIELD_CODEX_MODEL}: *//" | tr -d ' ' || true)
    STATE_CODEX_EFFORT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_EFFORT}:" | sed "s/${FIELD_CODEX_EFFORT}: *//" | tr -d ' ' || true)
    STATE_CODEX_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_TIMEOUT}:" | sed "s/${FIELD_CODEX_TIMEOUT}: *//" | tr -d ' ' || true)
    STATE_REVIEW_STARTED=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_REVIEW_STARTED}:" | sed "s/${FIELD_REVIEW_STARTED}: *//" | tr -d ' ' || true)
    STATE_FULL_REVIEW_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_FULL_REVIEW_ROUND}:" | sed "s/${FIELD_FULL_REVIEW_ROUND}: *//" | tr -d ' ' || true)
    STATE_ASK_CODEX_QUESTION=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_ASK_CODEX_QUESTION}:" | sed "s/${FIELD_ASK_CODEX_QUESTION}: *//" | tr -d ' ' || true)
    STATE_SESSION_ID=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_SESSION_ID}:" | sed "s/${FIELD_SESSION_ID}: *//" || true)
    STATE_AGENT_TEAMS=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_AGENT_TEAMS}:" | sed "s/${FIELD_AGENT_TEAMS}: *//" | tr -d ' ' || true)
    STATE_PRIVACY_MODE=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PRIVACY_MODE}:" | sed "s/${FIELD_PRIVACY_MODE}: *//" | tr -d ' ' || true)
    STATE_MAINLINE_STALL_COUNT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_MAINLINE_STALL_COUNT}:" | sed "s/${FIELD_MAINLINE_STALL_COUNT}: *//" | tr -d ' ' || true)
    STATE_LAST_MAINLINE_VERDICT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_LAST_MAINLINE_VERDICT}:" | sed "s/${FIELD_LAST_MAINLINE_VERDICT}: *//" | tr -d ' ' || true)
    STATE_DRIFT_STATUS=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_DRIFT_STATUS}:" | sed "s/${FIELD_DRIFT_STATUS}: *//" | tr -d ' ' || true)
}

# Parse state file frontmatter and set variables (tolerant mode with defaults)
# Usage: parse_state_file "$STATE_FILE"
# Sets the following variables (caller must declare them):
#   STATE_FRONTMATTER - raw frontmatter content
#   STATE_PLAN_TRACKED - "true" or "false"
#   STATE_START_BRANCH - branch name
#   STATE_BASE_BRANCH - base branch for code review
#   STATE_PLAN_FILE - plan file path
#   STATE_CURRENT_ROUND - current round number
#   STATE_MAX_ITERATIONS - max iterations
#   STATE_PUSH_EVERY_ROUND - "true" or "false"
#   STATE_CODEX_MODEL - codex model name
#   STATE_CODEX_EFFORT - codex effort level
#   STATE_CODEX_TIMEOUT - codex timeout in seconds
#   STATE_REVIEW_STARTED - "true" or "false"
#   STATE_FULL_REVIEW_ROUND - interval for Full Alignment Check (default: 5)
#   STATE_ASK_CODEX_QUESTION - "true" or "false" (v1.6.5+)
#   STATE_AGENT_TEAMS - "true" or "false"
#   STATE_MAINLINE_STALL_COUNT - consecutive stalled/regressed implementation rounds
#   STATE_LAST_MAINLINE_VERDICT - advanced/stalled/regressed/unknown
#   STATE_DRIFT_STATUS - normal/replan_required
# Returns: 0 on success, 1 if file not found
# Note: For strict validation, use parse_state_file_strict() instead
parse_state_file() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    STATE_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    _parse_state_fields

    # Apply defaults for non-schema-critical fields only
    # Note: review_started is NOT defaulted here so we can detect missing schema fields
    # and block with a proper message in the stop hook
    STATE_CURRENT_ROUND="${STATE_CURRENT_ROUND:-0}"
    STATE_MAX_ITERATIONS="${STATE_MAX_ITERATIONS:-10}"
    STATE_PUSH_EVERY_ROUND="${STATE_PUSH_EVERY_ROUND:-false}"
    STATE_FULL_REVIEW_ROUND="${STATE_FULL_REVIEW_ROUND:-5}"
    STATE_ASK_CODEX_QUESTION="${STATE_ASK_CODEX_QUESTION:-true}"
    STATE_AGENT_TEAMS="${STATE_AGENT_TEAMS:-false}"
    # Default privacy_mode to "true" for legacy loops that pre-date this field
    STATE_PRIVACY_MODE="${STATE_PRIVACY_MODE:-true}"
    STATE_MAINLINE_STALL_COUNT="${STATE_MAINLINE_STALL_COUNT:-0}"
    STATE_LAST_MAINLINE_VERDICT="${STATE_LAST_MAINLINE_VERDICT:-$MAINLINE_VERDICT_UNKNOWN}"
    STATE_DRIFT_STATUS="${STATE_DRIFT_STATUS:-$DRIFT_STATUS_NORMAL}"
    # STATE_REVIEW_STARTED left as-is (empty if missing, to allow schema validation)

    return 0
}

# Strict state file parser that rejects malformed files
# Usage: parse_state_file_strict "$STATE_FILE"
# Sets the same variables as parse_state_file()
# Returns: 0 on success, non-zero on validation failure
#   1 - file not found
#   2 - missing YAML frontmatter separators
#   3 - missing required field (current_round or max_iterations)
#   4 - non-numeric current_round value
#   5 - non-numeric max_iterations value
parse_state_file_strict() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        echo "Error: State file not found: $state_file" >&2
        return 1
    fi

    # Check for YAML frontmatter separators (must have at least two --- lines)
    local separator_count
    separator_count=$(grep -c '^---$' "$state_file" 2>/dev/null || echo "0")
    if [[ "$separator_count" -lt 2 ]]; then
        echo "Error: Missing YAML frontmatter separators (---)" >&2
        return 2
    fi

    # Extract frontmatter and parse all fields (reuse shared helper, no defaults applied)
    STATE_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")
    _parse_state_fields

    # Validate required fields exist
    if [[ -z "$STATE_CURRENT_ROUND" ]]; then
        echo "Error: Missing required field: current_round" >&2
        return 3
    fi
    if [[ -z "$STATE_MAX_ITERATIONS" ]]; then
        echo "Error: Missing required field: max_iterations" >&2
        return 3
    fi
    if [[ -z "$STATE_REVIEW_STARTED" ]]; then
        echo "Error: Missing required field: review_started" >&2
        return 3
    fi
    if [[ -z "$STATE_BASE_BRANCH" ]]; then
        echo "Error: Missing required field: base_branch" >&2
        return 3
    fi

    # Validate current_round is numeric (including 0 and negative)
    if ! [[ "$STATE_CURRENT_ROUND" =~ ^-?[0-9]+$ ]]; then
        echo "Error: Non-numeric current_round value: $STATE_CURRENT_ROUND" >&2
        return 4
    fi

    # Validate max_iterations is numeric
    if ! [[ "$STATE_MAX_ITERATIONS" =~ ^-?[0-9]+$ ]]; then
        echo "Error: Non-numeric max_iterations value: $STATE_MAX_ITERATIONS" >&2
        return 5
    fi

    # Validate review_started is boolean
    if [[ "$STATE_REVIEW_STARTED" != "true" && "$STATE_REVIEW_STARTED" != "false" ]]; then
        echo "Error: Invalid review_started value (must be true or false): $STATE_REVIEW_STARTED" >&2
        return 6
    fi

    # Apply defaults for optional fields only
    STATE_PUSH_EVERY_ROUND="${STATE_PUSH_EVERY_ROUND:-false}"
    STATE_FULL_REVIEW_ROUND="${STATE_FULL_REVIEW_ROUND:-5}"
    STATE_ASK_CODEX_QUESTION="${STATE_ASK_CODEX_QUESTION:-true}"
    STATE_AGENT_TEAMS="${STATE_AGENT_TEAMS:-false}"
    STATE_PRIVACY_MODE="${STATE_PRIVACY_MODE:-true}"
    STATE_MAINLINE_STALL_COUNT="${STATE_MAINLINE_STALL_COUNT:-0}"
    STATE_LAST_MAINLINE_VERDICT="${STATE_LAST_MAINLINE_VERDICT:-$MAINLINE_VERDICT_UNKNOWN}"
    STATE_DRIFT_STATUS="${STATE_DRIFT_STATUS:-$DRIFT_STATUS_NORMAL}"

    return 0
}

# Normalize mainline progress verdict to a safe enum.
# Usage: normalize_mainline_progress_verdict "ADVANCED"
normalize_mainline_progress_verdict() {
    local verdict_lower
    verdict_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    case "$verdict_lower" in
        "$MAINLINE_VERDICT_ADVANCED"|"$MAINLINE_VERDICT_STALLED"|"$MAINLINE_VERDICT_REGRESSED")
            echo "$verdict_lower"
            ;;
        *)
            echo "$MAINLINE_VERDICT_UNKNOWN"
            ;;
    esac
}

# Normalize drift status to a safe enum.
# Usage: normalize_drift_status "replan_required"
normalize_drift_status() {
    local status_lower
    status_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    case "$status_lower" in
        "$DRIFT_STATUS_REPLAN_REQUIRED")
            echo "$DRIFT_STATUS_REPLAN_REQUIRED"
            ;;
        *)
            echo "$DRIFT_STATUS_NORMAL"
            ;;
    esac
}

# Extract "Mainline Progress Verdict" from Codex review content.
# Outputs one of: advanced, stalled, regressed, unknown
# Usage: extract_mainline_progress_verdict "$review_content"
extract_mainline_progress_verdict() {
    local review_content="$1"
    local verdict_line
    local verdict_value

    verdict_line=$(printf '%s\n' "$review_content" | grep -Ei 'Mainline Progress Verdict:[[:space:]]*(ADVANCED|STALLED|REGRESSED)([^A-Za-z]|$)' | tail -1 || true)
    if [[ -z "$verdict_line" ]]; then
        echo "$MAINLINE_VERDICT_UNKNOWN"
        return
    fi

    # Extract the verdict word using grep -oEi (portable) instead of sed /I (GNU-only).
    # The preceding grep -Ei already ensures the line contains one of the three verdicts.
    # Reject lines with multiple verdict keywords (e.g. placeholder template formats)
    # to avoid silently accepting an ambiguous verdict.
    local _verdict_matches
    _verdict_matches=$(printf '%s\n' "$verdict_line" | grep -oEi 'ADVANCED|STALLED|REGRESSED')
    local _match_count
    _match_count=$(printf '%s\n' "$_verdict_matches" | wc -l)
    if [[ "$_match_count" -gt 1 ]]; then
        echo "$MAINLINE_VERDICT_UNKNOWN"
        return
    fi
    verdict_value=$(printf '%s\n' "$_verdict_matches" | head -1)
    normalize_mainline_progress_verdict "$verdict_value"
}

# Upsert simple YAML frontmatter fields in a state file.
# Values must not contain newlines.
# Usage: upsert_state_fields "/path/to/state.md" "field=value" "other=value"
upsert_state_fields() {
    local state_file="$1"
    shift

    local temp_file="${state_file}.tmp.$$"

    awk -v assignments="$*" '
        BEGIN {
            count = split(assignments, pairs, " ");
            for (i = 1; i <= count; i++) {
                eq = index(pairs[i], "=");
                key = substr(pairs[i], 1, eq - 1);
                val = substr(pairs[i], eq + 1);
                keys[key] = val;
                order[i] = key;
            }
            separator_count = 0;
        }
        {
            if ($0 == "---") {
                separator_count++;
                if (separator_count == 2) {
                    for (i = 1; i <= count; i++) {
                        key = order[i];
                        if (!(key in seen)) {
                            print key ": " keys[key];
                            seen[key] = 1;
                        }
                    }
                }
                print;
                next;
            }

            handled = 0;
            for (i = 1; i <= count; i++) {
                key = order[i];
                if ($0 ~ ("^" key ":")) {
                    print key ": " keys[key];
                    seen[key] = 1;
                    handled = 1;
                    break;
                }
            }

            if (!handled) {
                print;
            }
        }
    ' "$state_file" > "$temp_file" && mv "$temp_file" "$state_file"
}

# A human-readable note that a review came back clean. It is NOT provenance:
# nothing decides anything from it, because a findings record is copied verbatim
# from review output and could contain any line at all. It carries no bracketed
# token, because the review readers score one that is not a single digit as a
# malformed marker.
readonly CLEAN_REVIEW_MARKER="Result: clean"

REVIEW_MARKER_SCANNER="$LOOP_COMMON_PLUGIN_ROOT/scripts/review-markers.py"

# Ask the shared scanner about the first review marker in <file>.
#
# The grammar lives in `proof/core.py` and nowhere else. Keeping a second copy
# of it here in awk failed three times in a row -- on whether a marker must fit
# inside ten columns or merely start there, on byte versus character offsets
# once a line carried non-ASCII text, and on a token spanning a line break.
# Every one of them had the same shape: the shell called a review clean that the
# Proof layer reads as reporting a finding, and that record then resolves every
# finding still open in the Run.
#
# Prints the 1-based line number on stdout when it finds one, or with
# `--extract` the findings tail itself, cut from the same decoded text the
# grammar scanned. The line number must never be handed to another reader to
# re-locate the marker: `sed` and `wc` count raw `\n` bytes while the scanner
# counts lines of the decoded text, and that difference once moved an
# extraction past the marker it was extracting. Returns:
#   0 - found
#   1 - scanned, and there is no marker
#   2 - could not scan (no python3, unreadable or undecodable file, any error)
#
# 2 is never 1, and callers must not collapse them. Issue #28 is what that costs:
# a hook that tested only for its own failure codes treated `python3: command
# not found` (127) as a pass and skipped the gate silently.
# Usage: review_marker_line <file> [--canonical] [--tail N] [--extract]
review_marker_line() {
    local file="$1"
    shift
    local output
    local status=0
    output=$(python3 "$REVIEW_MARKER_SCANNER" "$file" "$@" 2>/dev/null) || status=$?
    case "$status" in
        0)
            printf '%s' "$output"
            return 0
            ;;
        1)
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}

# Best-effort ASCII scan for the extraction path only, used when the shared
# scanner cannot run. It is deliberately NOT used for the clean-review gate:
# extraction that misses a finding is the detection gap issue #36 already
# tracks, but an assertion that misses one is a false green.
#
# LC_ALL=C, deliberately: this scan is byte-oriented by design, and under a
# UTF-8 locale BSD awk aborts with "towc: multibyte conversion failure" on the
# first invalid byte -- before it reaches an ASCII marker on a later line, so
# the finding vanished and the loop finalized. The C locale makes awk read
# bytes, which is the only reading a fallback that exists for undecodable
# input can afford.
# Usage: review_marker_line_fallback <file>
review_marker_line_fallback() {
    LC_ALL=C awk '
        match($0, /\[P[0-9]\]/) && RSTART <= 10 {
            print NR
            exit
        }
    ' "$1" 2>/dev/null
}

# Detect review issues from codex review log file
# Returns:
#   0 - issues found (caller should continue review loop)
#   1 - no issues found, or the outcome is ambiguous (caller can proceed)
#   2 - hard analysis failure (caller must block and require retry): the log
#       is missing or empty, a stale all-clear was found and could not be
#       invalidated, or an existing record could not be classified safely.
#       Either way nothing about this round is established.
# Outputs: extracted review content to stdout if issues found
# Arguments: $1=round_number
# Required globals: LOOP_DIR, CACHE_DIR
#
# Algorithm:
# 1. Drop the round's previous all-clear, if one exists. An all-clear is an
#    assertion, not evidence, and each attempt must re-establish it; deciding
#    which record is an all-clear uses raw bytes (`grep -F '[P'`), so the
#    invalidation works even when the scanner cannot run -- which is exactly
#    when a stale assertion is most dangerous. An extracted findings record IS
#    evidence and is never dropped here. A stale all-clear that cannot be
#    removed, or a record the probe cannot classify at all, is a hard failure
#    (2): the unclassifiable record is preserved as evidence, and proceeding
#    would let a later ambiguous return of 1 finalize against it.
# 2. Ask the shared scanner for the findings tail: the first actionable [P?]
#    line within the last 50 lines, and everything after it, cut from the text
#    the scanner itself read. Real review issues only appear near the end of
#    the log; scanning the full file for extraction invites false positives
#    from earlier debug output.
# 3. If found: publish it as the round record and output it -- but only after
#    the scanner has re-read the exact bytes being published as still carrying
#    an actionable marker. A record that fails that re-scan is not published at
#    all: the caller still sees the findings, and the round simply has no
#    record, which resolves nothing.
# 4. If not found, scan the WHOLE log for any marker-shaped token. Record the
#    clean result as a fact only when there is none -- and, symmetrically, only
#    after the written bytes re-scan as marker-free. Otherwise the outcome is
#    ambiguous and nothing is recorded.
#
# Extraction and assertion deliberately use different windows. Missing a finding
# in the window is a detection gap the loop has always had. Asserting a clean
# review that the log contradicts is a false green in the Proof Bundle, which is
# worse, so step 4 fails closed where step 2 does not.
#
# The publish-time re-scan in steps 3 and 4 is the load-bearing part. Four
# false-green paths in a row were each some reader disagreeing with some writer
# about the same bytes -- window, column, byte offset, line break. The re-scan
# asks the one authoritative reader about the one artifact that matters, the
# bytes being published, so a disagreement of any future shape withholds the
# record instead of publishing it.
#
# Optional globals: CODEX_REVIEWED_BASE, CODEX_REVIEWED_COMMIT -- recorded into
# the clean-review result when the caller captured them, "not recorded" when it
# did not, so this stays usable outside the Stop hook.
#
# Note: codex review outputs to stderr, so we analyze the combined log file
# which contains both stdout and stderr (redirected with 2>&1).
detect_review_issues() {
    local round="$1"
    local log_file="$CACHE_DIR/round-${round}-codex-review.log"
    local result_file="$LOOP_DIR/round-${round}-review-result.md"

    # Check if log file exists and is not empty
    if [[ ! -f "$log_file" || ! -s "$log_file" ]]; then
        echo "Error: Codex review log file not found or empty: $log_file" >&2
        return 2
    fi

    # A new attempt supersedes the round's previous all-clear before anything
    # is scanned. The all-clear is an assertion the attempt has yet to earn;
    # leaving the old one on disk means a retry whose scan cannot run finalizes
    # against an assertion nobody re-established. The byte probe below is the
    # structural test -- a findings record is copied verbatim from review
    # output and begins at the marker line that triggered extraction, so it
    # always carries "[P"; the all-clear this function writes never does --
    # and it deliberately needs no scanner: grep over raw bytes cannot diverge
    # on decoding, columns or line breaks.
    #
    # The probe's three outcomes each get their own answer, and the third is
    # the one that used to fail open. 0 is a findings record: evidence, kept,
    # scanning continues. 1 is the stale all-clear: deleted, or a hard failure
    # when deletion cannot be verified. Anything else means the record could
    # not be classified at all -- unreadable, ACL, transient I/O -- and that
    # is preserved AND blocking: deleting it might destroy a findings record,
    # while proceeding lets a later ambiguous return of 1 finalize against an
    # assertion nobody could even read. Keeping the bytes and refusing the
    # round is the only pairing that does neither.
    if [[ -f "$result_file" ]]; then
        local record_probe=0
        LC_ALL=C grep -qF '[P' "$result_file" || record_probe=$?
        if [[ "$record_probe" -eq 1 ]]; then
            # "Dropped" is itself an assertion, and it gets the same treatment
            # as every other one here: verified, or not made. An all-clear
            # classified stale but left on disk -- ACL, immutable flag,
            # read-only filesystem -- must surface as a hard failure, because
            # a later ambiguous path returns 1, the caller reads 1 as safe to
            # finalize, and export would then consume the exact record this
            # block exists to remove. -e and -L cover a failed unlink and a
            # concurrent recreation, symlink or otherwise.
            if ! rm -f "$result_file" 2>/dev/null; then
                echo "Error: could not invalidate the previous all-clear for round $round" >&2
                return 2
            fi
            if [[ -e "$result_file" || -L "$result_file" ]]; then
                echo "Error: previous all-clear remains for round $round; refusing to proceed against stale evidence" >&2
                return 2
            fi
            echo "Dropped the previous all-clear for round $round; this attempt must re-establish it" >&2
        elif [[ "$record_probe" -ne 0 ]]; then
            echo "Error: could not classify the previous review record for safe invalidation (status $record_probe)" >&2
            return 2
        fi
    fi

    echo "Analyzing log file: $log_file" >&2

    # Only extract from the last 50 lines - real issues appear near the end
    local scan_lines=50

    # The shared scanner cuts the findings tail out of the text it scanned, so
    # no line number crosses back into shell arithmetic. `sed` counting raw
    # `\n` bytes against the scanner counting decoded lines is how a bare-CR
    # progress line once moved the extraction past the marker -- publishing a
    # marker-free record that read as a clean review.
    local extracted_content=""
    local extract_status=0
    extracted_content=$(review_marker_line "$log_file" --canonical --tail "$scan_lines" --extract) \
        || extract_status=$?

    if [[ "$extract_status" -eq 2 ]]; then
        # No scanner. Extraction falls back to a best-effort ASCII scan, which
        # is what this function did before the scanner existed -- but the
        # fallback only informs the caller; it publishes no record. Publishing
        # is an assertion about what the review said, and every assertion here
        # must pass the shared grammar's re-scan, which is exactly what is
        # unavailable. A round without a record resolves nothing.
        echo "Marker scanner unavailable; falling back to an ASCII-only scan" >&2
        local total_lines start_line relative_line
        total_lines=$(wc -l < "$log_file")
        start_line=$((total_lines > scan_lines ? total_lines - scan_lines + 1 : 1))
        relative_line=$(tail -n "$scan_lines" "$log_file" | review_marker_line_fallback /dev/stdin)
        if [[ -n "$relative_line" && "$relative_line" -gt 0 ]]; then
            # tail, awk and sed all count raw "\n" bytes of the same file, so
            # this arithmetic is consistent with itself, unlike a scanner line
            # number would be.
            local found_line=$((start_line + relative_line - 1))
            extracted_content=$(sed -n "${found_line},\$p" "$log_file")
            echo "Found [P?] issue at line $found_line (fallback scan; no record published)" >&2
            printf '## Codex Review Issues\n\n%s\n' "$extracted_content"
            return 0
        fi
        extracted_content=""
    fi

    if [[ "$extract_status" -eq 0 && -n "$extracted_content" ]]; then
        # Publish through a temp file, atomically renamed only after the
        # scanner has re-read the exact bytes being published as still carrying
        # an actionable marker. This is the writer asking the authoritative
        # reader about the artifact itself: whatever future shape a
        # writer/reader disagreement takes, its product fails this re-scan and
        # is withheld rather than published. The caller still gets the
        # findings either way -- a withheld record costs the round its
        # evidence, never the loop its review.
        local tmp_file="${result_file}.tmp.$$"
        # `|| true`: a failed write must not abort the function under set -e --
        # the re-scan below reads the truncated or absent file, fails, and
        # withholds the record, which is the intended response to it.
        printf '%s\n' "$extracted_content" > "$tmp_file" || true
        local verify_status=0
        review_marker_line "$tmp_file" --canonical >/dev/null || verify_status=$?
        if [[ "$verify_status" -eq 0 ]]; then
            mv -f "$tmp_file" "$result_file"
            echo "Review issues extracted to: $result_file" >&2
        else
            rm -f "$tmp_file"
            echo "Extracted content failed its own re-scan (status $verify_status); no round record published" >&2
        fi

        printf '## Codex Review Issues\n\n%s\n' "$extracted_content"
        return 0
    fi

    # Nothing canonical in the extraction window. That is NOT the same as "the
    # review was clean", and the difference decides whether an all-clear may be
    # written at all.
    #
    # The window above is 50 lines because findings appear at the end and a
    # full-file scan invites false positives from earlier debug output. That
    # trade is right for *extraction*. It is wrong for *assertion*: a canonical
    # marker earlier in the log, or a marker-shaped token that is not a single
    # digit (`[P10]`, `[P0-9]`), means this function has not established that
    # the review was clean. Writing an all-clear there converts a silent miss
    # into durable evidence that no finding was reported -- and the Proof layer
    # then resolves every finding still open in the Run against it, which can
    # carry a Run with unfixed work to `accept`.
    #
    # So the whole log decides whether the record may be written, through the
    # shared scanner and with no fallback. Only "scanned, and there is no
    # marker" earns an all-clear. A marker anywhere withholds it, and so does a
    # scan that could not run: not looking is not the same as looking and seeing
    # nothing, and treating them alike is the fail-open shape of issue #28.
    local marker_anywhere=""
    local gate_status=0
    marker_anywhere=$(review_marker_line "$log_file") || gate_status=$?

    if [[ "$gate_status" -ne 1 ]]; then
        if [[ "$gate_status" -eq 2 ]]; then
            echo "Marker scanner could not read the log; not recording a clean review" >&2
        else
            echo "Marker at line $marker_anywhere is outside the extraction window or malformed; not recording a clean review" >&2
        fi
        return 1
    fi

    # A clean review is a fact, and until now it was the one review outcome the
    # Run did not keep. The verdict went only to the cache log, outside the Run,
    # so a finding raised in an earlier round had nothing later to close it: a
    # Run that fixed everything and passed its re-review still carried `open`
    # findings forever (issue #33).
    #
    # What is written is a fact-only record -- this round, the base it was
    # reviewed against, and that no severity-marked finding was reported. The
    # cache log is not copied: it runs to hundreds of lines of prompt and exec
    # trace with absolute paths in it, which a public profile would then have to
    # withhold, and none of it is what closes a finding.
    #
    # The text must not contain a bracketed severity token anywhere in the first
    # ten characters of a line. That is what the review readers scan for, and a
    # token that is not a single digit reads as a *malformed* marker, which
    # would make this round unparseable and leave the findings it was meant to
    # resolve `unverifiable` instead. Say "P0-P9" in prose, never in brackets.
    # The re-scan before the rename holds that rule the way the extraction
    # branch holds its own: the all-clear is published only if the written
    # bytes still read as marker-free to the grammar that will judge them.
    local tmp_file="${result_file}.tmp.$$"
    {
        printf '# Round %s Code Review Result\n\n' "$round"
        printf '%s\n' "$CLEAN_REVIEW_MARKER"
        printf 'Reviewed base: %s\n' "${CODEX_REVIEWED_BASE:-not recorded}"
        printf 'Reviewed commit: %s\n' "${CODEX_REVIEWED_COMMIT:-not recorded}"
        printf '\nNo severity-marked finding (P0 through P9) was reported by '
        printf 'codex review for this round.\n'
    } > "$tmp_file" || true
    # Two probes, both required: the grammar re-scan (what the Proof layer will
    # read) and the raw-byte probe (what the up-front invalidation will use to
    # classify this record on the next attempt). Publishing only what satisfies
    # both keeps the two classifiers in agreement by construction -- an
    # all-clear that carried "[P" anywhere would read clean to the grammar yet
    # be retained as a findings record by the probe, outliving the attempt it
    # belongs to.
    local verify_status=0
    review_marker_line "$tmp_file" >/dev/null || verify_status=$?
    local byte_probe=0
    LC_ALL=C grep -qF '[P' "$tmp_file" || byte_probe=$?
    if [[ "$verify_status" -eq 1 && "$byte_probe" -eq 1 ]]; then
        mv -f "$tmp_file" "$result_file"
        echo "Clean review recorded to: $result_file" >&2
    else
        rm -f "$tmp_file"
        echo "Clean record failed its own re-scan (grammar $verify_status, bytes $byte_probe); withholding it" >&2
    fi

    echo "No [P?] issues found in log file" >&2
    return 1
}

# Convert a string to lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Check if a path (lowercase) matches a round file pattern
# Usage: is_round_file "$lowercase_path" "summary|prompt|todos|contract"
is_round_file_type() {
    local path_lower="$1"
    local file_type="$2"

    echo "$path_lower" | grep -qE "round-[0-9]+-${file_type}\\.md\$"
}

# Extract round number from a filename
# Usage: extract_round_number "round-5-summary.md"
# Outputs the round number or empty string
extract_round_number() {
    local filename="$1"
    local filename_lower
    filename_lower=$(to_lower "$filename")

    # Use sed for portable regex extraction (works in both bash and zsh).
    # -E is required: "\|" alternation inside a BRE group is a GNU extension
    # that BSD sed (macOS) ignores, which made this return an empty round
    # number there and left the round-scoped access guards failing open.
    echo "$filename_lower" | sed -nE 's/.*round-([0-9]+)-(summary|prompt|todos|contract)\.md$/\1/p'
}

# Check if a file is in the allowlist for the active loop
# Usage: is_allowlisted_file "$file_path" "$active_loop_dir"
# Returns: 0 if allowlisted, 1 otherwise
is_allowlisted_file() {
    local file_path="$1"
    local active_loop_dir="$2"

    local allowlist=(
        "round-1-todos.md"
        "round-2-todos.md"
        "round-0-summary.md"
        "round-1-summary.md"
    )

    for allowed in "${allowlist[@]}"; do
        if [[ "$file_path" == "$active_loop_dir/$allowed" ]]; then
            return 0
        fi
    done

    return 1
}

# Standard message for blocking todos file access
# Usage: todos_blocked_message "Read|Write|Bash"
todos_blocked_message() {
    local action="$1"
    local fallback="# Todos File Access Blocked

Do NOT create or access round-*-todos.md files. Use the native Task tools instead (TaskCreate, TaskUpdate, TaskList)."

    load_and_render_safe "$TEMPLATE_DIR" "block/todos-file-access.md" "$fallback"
}

# Standard message for blocking prompt file writes
prompt_write_blocked_message() {
    local fallback="# Prompt File Write Blocked

You cannot write to round-*-prompt.md files. These contain instructions FROM Codex TO you."

    load_and_render_safe "$TEMPLATE_DIR" "block/prompt-file-write.md" "$fallback"
}

# Standard message for blocking state file modifications
state_file_blocked_message() {
    local fallback="# State File Modification Blocked

You cannot modify state.md. This file is managed by the loop system."

    load_and_render_safe "$TEMPLATE_DIR" "block/state-file-modification.md" "$fallback"
}

# Standard message for blocking finalize-state file modifications
finalize_state_file_blocked_message() {
    local fallback="# Finalize State File Modification Blocked

You cannot modify finalize-state.md. This file is managed by the loop system during the Finalize Phase."

    load_and_render_safe "$TEMPLATE_DIR" "block/finalize-state-file-modification.md" "$fallback"
}

# Standard message for blocking round contract access during Finalize Phase
# Usage: finalize_contract_blocked_message "read"
finalize_contract_blocked_message() {
    local action="$1"
    local fallback="# Finalize Contract Access Blocked

There is no active round contract during the Finalize Phase.

Do not {{ACTION}} historical round contract files.
Use finalize-summary.md for finalize-only notes and goal-tracker.md for current state."

    load_and_render_safe "$TEMPLATE_DIR" "block/finalize-contract-access.md" "$fallback" \
        "ACTION=$action"
}

# Standard message for blocking summary file modifications via Bash
# Usage: summary_bash_blocked_message "$correct_summary_path"
summary_bash_blocked_message() {
    local correct_path="$1"
    local fallback="# Bash Write Blocked

Do not use Bash commands to modify summary files. Use the Write or Edit tool instead: {{CORRECT_PATH}}"

    load_and_render_safe "$TEMPLATE_DIR" "block/summary-bash-write.md" "$fallback" "CORRECT_PATH=$correct_path"
}

# Standard message for blocking goal-tracker modifications via Bash in Round 0
# Usage: goal_tracker_bash_blocked_message "$correct_goal_tracker_path"
goal_tracker_bash_blocked_message() {
    local correct_path="$1"
    local fallback="# Bash Write Blocked

Do not use Bash commands to modify goal-tracker.md. Use the Write or Edit tool instead: {{CORRECT_PATH}}"

    load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-bash-write.md" "$fallback" "CORRECT_PATH=$correct_path"
}

# Check if a path (lowercase) targets goal-tracker.md
is_goal_tracker_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'goal-tracker\.md$'
}

# Extract the immutable section from a goal-tracker content stream.
# Supports both current trackers (with --- separator) and older trackers
# that jump directly from IMMUTABLE SECTION to MUTABLE SECTION.
extract_goal_tracker_immutable_from_stream() {
    awk '
        /^## IMMUTABLE SECTION[[:space:]]*$/ { capture=1 }
        capture && /^## MUTABLE SECTION[[:space:]]*$/ { exit }
        capture && /^---[[:space:]]*$/ { exit }
        capture { print }
    '
}

# Extract the immutable section from an on-disk goal-tracker file.
# Usage: extract_goal_tracker_immutable_from_file "/path/to/goal-tracker.md"
extract_goal_tracker_immutable_from_file() {
    local tracker_file="$1"
    if [[ ! -f "$tracker_file" ]]; then
        return 1
    fi
    extract_goal_tracker_immutable_from_stream < "$tracker_file"
}

# Extract the immutable section from an in-memory goal-tracker string.
# Usage: extract_goal_tracker_immutable_from_text "$content"
extract_goal_tracker_immutable_from_text() {
    local tracker_content="$1"
    printf '%s' "$tracker_content" | extract_goal_tracker_immutable_from_stream
}

# Check whether a proposed goal-tracker update preserves the immutable section.
# Usage: goal_tracker_mutable_update_allowed "/path/to/current.md" "$new_content"
goal_tracker_mutable_update_allowed() {
    local tracker_file="$1"
    local updated_content="$2"

    local current_immutable=""
    local updated_immutable=""
    current_immutable=$(extract_goal_tracker_immutable_from_file "$tracker_file" 2>/dev/null || true)
    updated_immutable=$(extract_goal_tracker_immutable_from_text "$updated_content" 2>/dev/null || true)

    # Legacy trackers without IMMUTABLE SECTION: allow edits unconditionally.
    [[ -n "$current_immutable" ]] || return 0
    [[ "$current_immutable" == "$updated_immutable" ]]
}

# Render the post-edit contents for a literal Edit operation.
# Returns non-zero if the edit preview cannot be produced.
# Usage: preview_edit_result "/path/to/file" "$old_string" "$new_string" "true|false"
preview_edit_result() {
    local file_path="$1"
    local old_string="$2"
    local new_string="$3"
    local replace_all="${4:-false}"

    command -v perl >/dev/null 2>&1 || return 1

    FILE_PATH="$file_path" \
    OLD_STRING="$old_string" \
    NEW_STRING="$new_string" \
    REPLACE_ALL="$replace_all" \
    perl -0pe '
        BEGIN {
            $old = $ENV{"OLD_STRING"};
            $new = $ENV{"NEW_STRING"};
            $replace_all = $ENV{"REPLACE_ALL"} eq "true";
        }
        if ($replace_all) {
            s/\Q$old\E/$new/g;
        } else {
            s/\Q$old\E/$new/;
        }
    ' "$file_path"
}

# Check if a path (lowercase) targets state.md
is_state_file_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'state\.md$'
}

# Check if a path (lowercase) targets finalize-state.md
is_finalize_state_file_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'finalize-state\.md$'
}

# Check if a path (lowercase) targets methodology-analysis-state.md
is_methodology_analysis_state_file_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'methodology-analysis-state\.md$'
}

# Standard message for blocking methodology-analysis-state file modifications
methodology_analysis_state_file_blocked_message() {
    local fallback="# Methodology Analysis State File Modification Blocked

You cannot modify methodology-analysis-state.md. This file is managed by the loop system during the Methodology Analysis Phase."

    load_and_render_safe "$TEMPLATE_DIR" "block/methodology-analysis-state-file-modification.md" "$fallback"
}

# Check if a path (lowercase) targets finalize-summary.md
is_finalize_summary_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'finalize-summary\.md$'
}

# Normalize paths by removing /./ and collapsing // to /
# This allows paths like /path/to/./state.md to match /path/to/state.md
_normalize_path() {
    echo "$1" | sed 's|/\./|/|g; s|//|/|g'
}

# Check if cancel operation is authorized via signal file
# Usage: is_cancel_authorized "$active_loop_dir" "$command_lower"
# Returns: 0 if authorized, non-zero otherwise
#   1 - missing signal file
#   2 - security violation (injection, command substitution, etc.)
#   3 - mixed quote styles
#   4 - multiple trailing spaces
#   5 - invalid command structure
#   6 - source file is a symlink (filesystem check)
#
# Security notes:
# - Normalizes $loop_dir/${loop_dir} to actual path before validation
# - Rejects $(cmd) command substitution and backticks
# - Rejects any remaining $ after normalization (prevents hidden vars like ${IFS})
# - Enforces exactly two arguments: state.md or finalize-state.md source and cancel-state.md dest
# - Rejects shell operators for command chaining
# - Rejects mixed quote styles and multiple trailing spaces
# - Rejects if source file is a symlink
is_cancel_authorized() {
    local active_loop_dir="$1"
    local command_lower="$2"

    local cancel_signal="$active_loop_dir/.cancel-requested"

    # Signal file must exist
    if [[ ! -f "$cancel_signal" ]]; then
        return 1
    fi

    # SECURITY: Reject command substitution and backticks
    if echo "$command_lower" | grep -qE '\$\(|`'; then
        return 2
    fi

    # Reject newlines (multi-command injection)
    if [[ "$command_lower" == *$'\n'* ]]; then
        return 2
    fi

    # Reject shell operators for command chaining
    if echo "$command_lower" | grep -qE ';|&&|\|\||\|'; then
        return 2
    fi

    # Reject multiple trailing spaces
    if echo "$command_lower" | grep -qE '[[:space:]]{2,}$'; then
        return 4
    fi

    # Canonicalize the loop dir (idempotent: resolve_project_root already
    # canonicalizes, but callers may supply a non-canonical override). Both
    # sides of the upcoming string comparisons must be canonicalized through
    # the same transformation or a symlinked prefix in the user's command
    # (e.g. /var/... vs /private/var/... on macOS) will spuriously fail the
    # authorization check.
    local canonical_loop_dir
    canonical_loop_dir="$(canonicalize_path "${active_loop_dir%/}")"
    canonical_loop_dir="${canonical_loop_dir:-${active_loop_dir%/}}"

    # Normalize: Replace $loop_dir and ${loop_dir} with actual path
    local normalized="$command_lower"
    local loop_dir_lower
    loop_dir_lower="${canonical_loop_dir}/"
    loop_dir_lower=$(echo "$loop_dir_lower" | tr '[:upper:]' '[:lower:]')

    normalized="${normalized//\$\{loop_dir\}/$loop_dir_lower}"
    normalized="${normalized//\$loop_dir/$loop_dir_lower}"

    # After normalization, reject any remaining $ (prevents hidden vars like ${IFS})
    if echo "$normalized" | grep -qE '\$'; then
        return 2
    fi

    # Must start with mv followed by space
    if ! echo "$normalized" | grep -qE '^mv[[:space:]]+'; then
        return 5
    fi

    # Extract arguments after "mv "
    local args
    args=$(echo "$normalized" | sed 's/^mv[[:space:]]*//')

    # Detect quote types used in both arguments
    # Check for mixed quotes by detecting if both ' and " are used as delimiters
    local has_single=false has_double=false
    local first_char
    first_char=$(echo "$args" | cut -c1)
    if [[ "$first_char" == '"' ]]; then
        has_double=true
    elif [[ "$first_char" == "'" ]]; then
        has_single=true
    fi

    # Skip first argument to check second
    local args_after_first
    if [[ "$first_char" == '"' ]]; then
        args_after_first=$(echo "$args" | sed 's/^"[^"]*"[[:space:]]*//')
    elif [[ "$first_char" == "'" ]]; then
        args_after_first=$(echo "$args" | sed "s/^'[^']*'[[:space:]]*//")
    else
        args_after_first=$(echo "$args" | sed 's/^[^[:space:]]*[[:space:]]*//')
    fi

    local second_char
    second_char=$(echo "$args_after_first" | cut -c1)
    if [[ "$second_char" == '"' ]]; then
        has_double=true
    elif [[ "$second_char" == "'" ]]; then
        has_single=true
    fi

    # Reject mixed quote styles
    if [[ "$has_single" == "true" ]] && [[ "$has_double" == "true" ]]; then
        return 3
    fi

    # Parse arguments, respecting quotes
    local src dest
    if echo "$args" | grep -qE "^[\"']"; then
        local quote_char
        quote_char=$(echo "$args" | cut -c1)
        if [[ "$quote_char" == '"' ]]; then
            src=$(echo "$args" | sed -n 's/^"\([^"]*\)".*/\1/p')
            args=$(echo "$args" | sed 's/^"[^"]*"[[:space:]]*//')
        else
            src=$(echo "$args" | sed -n "s/^'\\([^']*\\)'.*/\\1/p")
            args=$(echo "$args" | sed "s/^'[^']*'[[:space:]]*//")
        fi
    else
        src=$(echo "$args" | sed 's/[[:space:]].*//')
        args=$(echo "$args" | sed 's/^[^[:space:]]*[[:space:]]*//')
    fi

    if echo "$args" | grep -qE "^[\"']"; then
        local quote_char
        quote_char=$(echo "$args" | cut -c1)
        if [[ "$quote_char" == '"' ]]; then
            dest=$(echo "$args" | sed -n 's/^"\([^"]*\)".*/\1/p')
            args=$(echo "$args" | sed 's/^"[^"]*"[[:space:]]*//')
        else
            dest=$(echo "$args" | sed -n "s/^'\\([^']*\\)'.*/\\1/p")
            args=$(echo "$args" | sed "s/^'[^']*'[[:space:]]*//")
        fi
    else
        dest=$(echo "$args" | sed 's/[[:space:]].*//')
        args=$(echo "$args" | sed 's/^[^[:space:]]*//')
    fi

    if [[ -z "$src" ]] || [[ -z "$dest" ]]; then
        return 5
    fi

    # Check for extra arguments
    args=$(echo "$args" | sed 's/^[[:space:]]*//')
    if [[ -n "$args" ]]; then
        return 5
    fi

    # Normalize and validate source path.
    #
    # Use canonicalize_path_prefix (NOT canonicalize_path): we need to resolve
    # symlinks in the parent directory so a symlinked project prefix matches
    # canonical_loop_dir, but we MUST NOT dereference a symlink at the leaf.
    # Otherwise a symlink like /tmp/alias -> <loop>/state.md would canonicalize
    # to <loop>/state.md and pass the check, but `mv` would then operate on
    # the link path itself, escaping the loop directory and/or corrupting
    # loop state. The on-disk symlink rejection below (src_original check)
    # still fires because it probes the real state.md under canonical_loop_dir.
    #
    # Re-lowercase after canonicalization because realpath on case-insensitive
    # filesystems may restore the original casing of path components, which
    # would diverge from the already-lowercased expected_* values.
    src=$(_normalize_path "$src")
    local src_canonical
    src_canonical="$(canonicalize_path_prefix "$src")"
    src_canonical="${src_canonical:-$src}"
    src_canonical=$(echo "$src_canonical" | tr '[:upper:]' '[:lower:]')
    local expected_src_state="${loop_dir_lower}state.md"
    local expected_src_finalize="${loop_dir_lower}finalize-state.md"
    local expected_src_methodology="${loop_dir_lower}methodology-analysis-state.md"
    if [[ "$src_canonical" != "$expected_src_state" ]] && [[ "$src_canonical" != "$expected_src_finalize" ]] && [[ "$src_canonical" != "$expected_src_methodology" ]]; then
        return 5
    fi

    # Normalize and validate destination path. Uses canonicalize_path_prefix
    # for the same reason as src: a symlink alias pointing at the real
    # cancel-state.md must NOT pass authorization, because `mv` onto a
    # symlink replaces the link rather than creating <loop>/cancel-state.md,
    # corrupting loop state and moving state.md outside the loop dir.
    dest=$(_normalize_path "$dest")
    local dest_canonical
    dest_canonical="$(canonicalize_path_prefix "$dest")"
    dest_canonical="${dest_canonical:-$dest}"
    dest_canonical=$(echo "$dest_canonical" | tr '[:upper:]' '[:lower:]')
    local expected_dest="${loop_dir_lower}cancel-state.md"
    if [[ "$dest_canonical" != "$expected_dest" ]]; then
        return 5
    fi

    # SECURITY: Reject if source file is a symlink (filesystem check)
    # Determine source file by comparing against expected paths (not substring match)
    # This avoids vulnerability when loop directory path contains "finalize" or "methodology"
    # Use canonical_loop_dir so the symlink check runs against the real on-disk
    # path rather than a user-supplied non-canonical form.
    local src_original
    if [[ "$src_canonical" == "$expected_src_methodology" ]]; then
        src_original="${canonical_loop_dir}/methodology-analysis-state.md"
    elif [[ "$src_canonical" == "$expected_src_finalize" ]]; then
        src_original="${canonical_loop_dir}/finalize-state.md"
    else
        src_original="${canonical_loop_dir}/state.md"
    fi
    if [[ -L "$src_original" ]]; then
        return 6  # Source is a symlink
    fi

    return 0
}

# Check if a path is inside .loop/rlcr directory
is_in_loop_loop_dir() {
    local path="$1"
    echo "$path" | grep -q '\.loop/rlcr/'
}

# Check if a git add command would add .loop files to version control
# Usage: git_adds_loop "$command_lower"
# Returns 0 if the command would add .loop files, 1 otherwise
#
# IMPORTANT: This function receives LOWERCASED input from the validator.
# Git flags like -A become -a after lowercasing, so we match both.
#
# Handles:
# - git -C <dir> add (git options before add subcommand)
# - Chained commands: cd repo && git add .loop
# - Shell operators: ;, &&, ||, |
#
# Blocks:
# - git add .loop or git add .loop/
# - git add .loop/* or git add .loop/**
# - git add -f .loop* (force add)
# - git add -f . or git add --force . (force add all - bypasses gitignore)
# - git add -f -A or git add --force --all (force add all)
# - git add -fA or similar combined flags
# - git add -A or git add --all (when .loop exists)
# - git add . or git add * (when .loop exists and not gitignored)
#
git_adds_loop() {
    local cmd="$1"

    # Split command on shell operators and check each segment
    # This handles chained commands like: cd repo && git add .loop
    local segments
    segments=$(echo "$cmd" | sed '
        s/&&/\n/g
        s/||/\n/g
        s/|/\n/g
        s/;/\n/g
    ')

    while IFS= read -r segment; do
        [[ -z "$segment" ]] && continue

        # Check if this segment contains a git add command
        # Pattern: git (with optional flags/options) followed by add
        # Handles:
        # - git add
        # - git -C dir add (short option with separate arg)
        # - git --git-dir=x add (long option with = arg)
        # - git -c key=value add (short option with = arg)
        # The pattern allows any non-add tokens between git and add
        if ! echo "$segment" | grep -qE '(^|[[:space:]])git[[:space:]]+([^[:space:]]+[[:space:]]+)*add([[:space:]]|$)'; then
            continue
        fi

        # Extract the part after "add" for analysis
        local add_args
        add_args=$(echo "$segment" | sed -n 's/.*[[:space:]]add[[:space:]]*//p')

        # Normalize add_args: strip quotes for path matching
        # This handles: git add ".loop", git add '.loop'
        local add_args_normalized
        add_args_normalized=$(echo "$add_args" | sed "s/[\"']//g")

        # Check for direct .loop reference (blocked regardless of other flags)
        # Handles: .loop, ./.loop, path/to/.loop, ".loop", '.loop'
        # Pattern matches .loop at start, after space, after / or ./ AND followed by end, /, or space
        # This avoids over-blocking .loopconfig or .loop-backup.
        if echo "$add_args_normalized" | grep -qE '(^|[[:space:]]|/)\.loop($|/|[[:space:]])'; then
            return 0
        fi

        # Check for -f or --force flag (including combined flags like -fa, -af)
        local has_force=false
        if echo "$add_args" | grep -qE '(^|[[:space:]])--force([[:space:]]|$)'; then
            has_force=true
        elif echo "$add_args" | grep -qE '(^|[[:space:]])-[a-z]*f[a-z]*([[:space:]]|$)'; then
            has_force=true
        fi

        # Check for -A/--all flag (including combined flags like -fa, -af)
        # Note: input is lowercased, so -A becomes -a
        local has_all=false
        if echo "$add_args" | grep -qE '(^|[[:space:]])--all([[:space:]]|$)'; then
            has_all=true
        elif echo "$add_args" | grep -qE '(^|[[:space:]])-[a-z]*a[a-z]*([[:space:]]|$)'; then
            has_all=true
        fi

        # Check for broad scope targets: . or * alone
        local has_broad_scope=false
        if echo "$add_args" | grep -qE '(^|[[:space:]])(\.|\*)([[:space:]]|$)'; then
            has_broad_scope=true
        fi

        # Force add with any broad scope (force bypasses gitignore entirely)
        if [[ "$has_force" == "true" ]]; then
            if [[ "$has_all" == "true" ]] || [[ "$has_broad_scope" == "true" ]]; then
                return 0
            fi
        fi

        # Check if .loop exists - needed for non-force blocking
        if [[ ! -d ".loop" ]]; then
            continue
        fi

        # git add -A/--all when .loop exists
        # Always block because -A adds all changes including untracked files
        if [[ "$has_all" == "true" ]]; then
            return 0
        fi

        # git add . or git add * when .loop exists and not gitignored
        # Only block if .loop is NOT protected by gitignore
        if [[ "$has_broad_scope" == "true" ]]; then
            if ! git check-ignore -q .loop 2>/dev/null; then
                return 0
            fi
        fi
    done <<< "$segments"

    return 1
}

# Standard message for blocking git add .loop commands
# Usage: git_add_loop_blocked_message
git_add_loop_blocked_message() {
    local fallback="# Git Add Blocked: .loop Protection

The \`.loop/\` directory contains local loop state that should NOT be committed.

Your command was blocked because it would add .loop files to version control.

## Allowed Commands

Use specific file paths instead of broad patterns:

    git add <specific-file>
    git add src/
    git add -p  # patch mode

## Blocked Commands

These commands are blocked when .loop exists:

    git add .loop      # direct reference
    git add -A             # adds all including .loop
    git add --all          # adds all including .loop
    git add .              # may include .loop if not gitignored
    git add -f .           # force bypasses gitignore

## Adding .loop to .gitignore

If you need to add \`.loop*\` to \`.gitignore\`, follow these steps:

1. Edit \`.gitignore\` to append \`.loop*\`
2. Run: \`git add .gitignore\`
3. Run: \`git commit -m \"Add loop local folder into gitignore\"\`

IMPORTANT: The commit message must NOT contain the literal string \".loop\" to avoid triggering this protection."

    load_and_render_safe "$TEMPLATE_DIR" "block/git-add-loop.md" "$fallback"
}

# Return success if local Loop runtime state has entered git tracking or the index.
# Untracked .loop state is allowed; tracked or staged state must be blocked.
# Usage: git_has_tracked_loop_state [project_root]
#
# Intentionally scoped to .loop/ to stay consistent with git_adds_loop,
# which explicitly allows unrelated paths like .loop-backup or
# .loopconfig (see tests/test-loop-escape.sh). ls-files covers both
# committed entries and paths staged via git add; paths the user has staged for
# removal via git rm --cached are correctly omitted so the user can unstick
# themselves without being re-blocked.
git_has_tracked_loop_state() {
    local project_root="${1:-.}"

    if [[ ! -d "$project_root/.git" ]] && ! git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
        return 1
    fi

    if git -C "$project_root" ls-files -- .loop 2>/dev/null | grep -q '.'; then
        return 0
    fi

    return 1
}

# Standard message for blocking tracked/staged .loop state.
# Usage: git_tracked_loop_blocked_message
git_tracked_loop_blocked_message() {
    local fallback="# Tracked Loop State Blocked

Detected tracked or staged files under \`.loop/\`.

These files are local Loop state and must remain outside version control.

## Required Fix

1. Remove Loop state from the index:

       git rm --cached -r .loop

2. Keep only real project files staged.
3. Retry the stop action after the local state is no longer tracked.

## Important

- Do NOT use \`git add -f\` on Loop state files.
- Do NOT commit RLCR trackers, round summaries, contracts, or cancel/finalize markers."

    load_and_render_safe "$TEMPLATE_DIR" "block/git-tracked-loop.md" "$fallback"
}

# Standard message for blocking direct execution of hook scripts
# Usage: stop_hook_direct_execution_blocked_message
stop_hook_direct_execution_blocked_message() {
    local fallback="# Direct Execution of Hook Scripts Blocked

You are attempting to directly execute a hook script via Bash. This is not allowed during an active loop.

Hook scripts are managed by the hooks system and are triggered automatically at the appropriate time. You should NOT execute them manually.

Simply complete your work and end your response. The hooks system will handle the rest automatically."

    load_and_render_safe "$TEMPLATE_DIR" "block/stop-hook-direct-execution.md" "$fallback"
}

# Check if a shell command attempts to modify a file matching the given pattern
# Usage: command_modifies_file "$command_lower" "goal-tracker\.md"
# Returns 0 if the command tries to modify the file, 1 otherwise
command_modifies_file() {
    local command_lower="$1"
    local file_pattern="$2"

    local patterns=(
        ">[[:space:]]*[^[:space:]]*${file_pattern}"
        ">>[[:space:]]*[^[:space:]]*${file_pattern}"
        "tee[[:space:]]+(-a[[:space:]]+)?[^[:space:]]*${file_pattern}"
        "sed[[:space:]]+-i[^|]*${file_pattern}"
        "awk[[:space:]]+-i[[:space:]]+inplace[^|]*${file_pattern}"
        "perl[[:space:]]+-[^[:space:]]*i[^|]*${file_pattern}"
        "(mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]*${file_pattern}"
        "rm[[:space:]]+(-[rfv]+[[:space:]]+)?[^[:space:]]*${file_pattern}"
        "dd[[:space:]].*of=[^[:space:]]*${file_pattern}"
        "truncate[[:space:]]+[^|]*${file_pattern}"
        "printf[[:space:]].*>[[:space:]]*[^[:space:]]*${file_pattern}"
        "exec[[:space:]]+[0-9]*>[[:space:]]*[^[:space:]]*${file_pattern}"
    )

    for pattern in "${patterns[@]}"; do
        if echo "$command_lower" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Standard message for blocking goal-tracker modifications after Round 0
# Usage: goal_tracker_blocked_message "$current_round" "$correct_goal_tracker_path"
goal_tracker_blocked_message() {
    local current_round="$1"
    local correct_path="$2"
    local fallback="# Goal Tracker Update Blocked (Round {{CURRENT_ROUND}})

After Round 0, you may update only the **MUTABLE SECTION** of the active goal tracker.

Use Write or Edit on: {{CORRECT_PATH}}

Rules:
- Keep the **IMMUTABLE SECTION** unchanged
- Do not modify \`goal-tracker.md\` via Bash
- Do not write to an old loop session's tracker"

    load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-modification.md" "$fallback" \
        "CURRENT_ROUND=$current_round" \
        "CORRECT_PATH=$correct_path"
}

# Record the true HEAD commit and end timestamp into a state file's
# frontmatter (D17 Run Recorder). Best-effort: git failures leave the
# fields absent rather than blocking the exit path that calls this.
#
# Usage: record_head_commit_and_ended_at "$state_file" "$project_root"
record_head_commit_and_ended_at() {
    local state_file="$1"
    local project_root="$2"

    [[ -z "$state_file" || ! -f "$state_file" ]] && return 0

    local head_commit
    head_commit=$(run_with_timeout "$GIT_TIMEOUT" git -C "$project_root" rev-parse HEAD 2>/dev/null || true)
    [[ -z "$head_commit" ]] && return 0

    local ended_at
    ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Unlike persist_session_id_if_empty's replace-only pattern, this must
    # insert the fields when absent: state.md's template (setup-rlcr-loop.sh)
    # never pre-declares head_commit/ended_at as empty placeholder lines the
    # way it does for session_id, so a replace-only match would silently
    # no-op on every real state file. upsert_state_fields inserts-or-replaces.
    upsert_state_fields "$state_file" \
        "${FIELD_HEAD_COMMIT}=${head_commit}" \
        "${FIELD_ENDED_AT}=${ended_at}"
}

# End the loop by renaming state.md to indicate exit reason
# Usage: end_loop "$loop_dir" "$state_file" "complete|cancel|maxiter|stop|unexpected"
# Arguments:
#   $1 - loop_dir: Path to the loop directory
#   $2 - state_file: Path to the state.md file
#   $3 - reason: One of complete, cancel, maxiter, stop, unexpected
#   $4 - project_root (optional): repo root to resolve HEAD from; when
#        omitted, head_commit/ended_at are not appended (caller already
#        recorded them, e.g. via record_head_commit_and_ended_at)
# Returns: 0 on success, 1 on failure
end_loop() {
    local loop_dir="$1"
    local state_file="$2"
    local reason="$3"  # complete, cancel, maxiter, stop, unexpected
    local project_root="${4:-}"

    # Validate reason
    case "$reason" in
        complete|cancel|maxiter|stop|unexpected)
            ;;
        *)
            echo "Error: Invalid end_loop reason: $reason" >&2
            return 1
            ;;
    esac

    local target_name="${reason}-state.md"

    if [[ -f "$state_file" ]]; then
        [[ -n "$project_root" ]] && record_head_commit_and_ended_at "$state_file" "$project_root"
        mv "$state_file" "$loop_dir/$target_name"
        echo "Loop ended: $reason" >&2
        echo "State preserved as: $loop_dir/$target_name" >&2
        return 0
    else
        echo "Warning: State file not found, cannot end loop" >&2
        return 1
    fi
}

# Source background-task helpers. Sourced at the bottom so every function
# above is available to callers that only need loop-common.sh, while bg-aware
# callers (the stop hook, the test suite) still get the bg helpers via a
# single source of loop-common.sh.
#
# _LOOP_COMMON_DIR is set here instead of at the top of the file because
# loop-bg-tasks.sh lives in the same directory as this file and we want to
# locate it regardless of how loop-common.sh was sourced.
_LOOP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=loop-bg-tasks.sh
source "$_LOOP_COMMON_DIR/loop-bg-tasks.sh"
