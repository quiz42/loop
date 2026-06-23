#!/usr/bin/env bash
# Compatibility wrapper for Python template helpers.

_HUMANIZE_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

get_template_dir() {
    python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" template-dir "$1"
}

load_template() {
    python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" load "$1" "$2"
}

render_template() {
    local content="$1"
    shift
    printf '%s' "$content" | python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" render "$@"
}

load_and_render() {
    local template_dir="$1"
    local template_name="$2"
    shift 2
    python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" load-render "$template_dir" "$template_name" "$@"
}

load_and_render_safe() {
    local template_dir="$1"
    local template_name="$2"
    local fallback_msg="$3"
    shift 3
    local rendered
    rendered=$(python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" load-render "$template_dir" "$template_name" "$@" 2>/dev/null || true)
    if [[ -n "$rendered" ]]; then
        printf '%s\n' "$rendered"
    else
        printf '%s' "$fallback_msg" | python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" render "$@"
    fi
}

append_template() {
    local base_content="$1"
    local template_dir="$2"
    local template_name="$3"
    printf '%s\n' "$base_content"
    python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" load "$template_dir" "$template_name" 2>/dev/null || true
}

validate_template_dir() {
    python3 "$_HUMANIZE_HOOK_LIB_DIR/template_loader.py" validate "$1"
}
