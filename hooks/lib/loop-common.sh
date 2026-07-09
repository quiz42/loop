#!/usr/bin/env bash
# Compatibility wrapper for Python shared loop helpers.

_LOOP_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$_LOOP_HOOK_LIB_DIR/project-root.sh"
source "$_LOOP_HOOK_LIB_DIR/template-loader.sh"
source "$_LOOP_HOOK_LIB_DIR/loop-bg-tasks.sh"

FIELD_CURRENT_ROUND="current_round"
FIELD_MAX_ITERATIONS="max_iterations"
FIELD_SESSION_ID="session_id"
MAINLINE_VERDICT_UNKNOWN="unknown"
DRIFT_STATUS_NORMAL="normal"
EXIT_COMPLETE="complete"
EXIT_CANCEL="cancel"
EXIT_MAXITER="maxiter"
EXIT_STOP="stop"
EXIT_UNEXPECTED="unexpected"

extract_session_id() {
    python3 - "$1" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("session_id", ""))
except Exception:
    print("")
PY
}

resolve_active_state_file() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_common.py" active-state "$1"
}

get_current_round() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_common.py" current-round "$1"
}

git_adds_loop() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_common.py" git-adds-loop "$1" "${2:-.}"
}

command_modifies_file() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_common.py" command-modifies-file "$1" "$2"
}

extract_mainline_progress_verdict() {
    local tmp
    tmp=$(mktemp)
    printf '%s' "$1" > "$tmp"
    python3 "$_LOOP_HOOK_LIB_DIR/loop_common.py" verdict "$tmp"
    rm -f "$tmp"
}

to_lower() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}
