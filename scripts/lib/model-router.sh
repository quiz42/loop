#!/usr/bin/env bash
# Shell compatibility wrapper for loop model routing.

[[ -n "${_MODEL_ROUTER_LOADED:-}" ]] && return 0 2>/dev/null || true
_MODEL_ROUTER_LOADED=1

_model_router_python() {
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/model_router.py" "$@"
}

detect_provider() {
    if [[ $# -ne 1 ]]; then
        echo "Error: Model name must be non-empty." >&2
        return 1
    fi
    _model_router_python detect-provider "$1"
}

check_provider_dependency() {
    if [[ $# -ne 1 ]]; then
        echo "Error: Unknown provider ''. Expected 'codex' or 'claude'." >&2
        return 1
    fi
    _model_router_python check-provider-dependency "$1"
}

map_effort() {
    if [[ $# -ne 2 ]]; then
        echo "Error: Usage: map_effort <effort> <target_provider>" >&2
        return 1
    fi
    _model_router_python map-effort "$1" "$2"
}
