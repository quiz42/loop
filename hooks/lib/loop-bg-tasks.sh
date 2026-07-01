#!/usr/bin/env bash
# Compatibility wrapper for Python loop background-task helpers.

_LOOP_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

expand_leading_tilde() {
    python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
if path == "~":
    print(os.environ.get("HOME", ""), end="")
elif path.startswith("~/"):
    print(f"{os.environ.get('HOME', '')}/{path[2:]}", end="")
else:
    print(path, end="")
PY
}

extract_transcript_path() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_bg_tasks.py" extract-transcript "$1"
}

derive_loop_start_iso_ts() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_bg_tasks.py" loop-start "$1"
}

derive_tasks_dir_from_transcript() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_bg_tasks.py" tasks-dir "$1"
}

list_pending_background_task_ids() {
    python3 "$_LOOP_HOOK_LIB_DIR/loop_bg_tasks.py" pending "$1" "${2:-}"
}

has_pending_background_tasks() {
    [[ -n "$(list_pending_background_task_ids "$1" "${2:-}" 2>/dev/null)" ]]
}

count_pending_background_tasks() {
    list_pending_background_task_ids "$1" "${2:-}" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' '
}
