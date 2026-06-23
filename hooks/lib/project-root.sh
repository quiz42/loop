#!/usr/bin/env bash
# Compatibility wrapper for Python project-root helpers.

_HUMANIZE_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

resolve_project_root() {
    python3 "$_HUMANIZE_HOOK_LIB_DIR/project_root.py" root
}

canonicalize_path_prefix() {
    python3 "$_HUMANIZE_HOOK_LIB_DIR/project_root.py" canonicalize-prefix "$1"
}

canonicalize_path() {
    python3 "$_HUMANIZE_HOOK_LIB_DIR/project_root.py" canonicalize "$1"
}
