#!/usr/bin/env bash
# Shell compatibility wrapper for humanize-loop configuration loading.

[[ -n "${_CONFIG_LOADER_LOADED:-}" ]] && return 0 2>/dev/null || true
_CONFIG_LOADER_LOADED=1

_config_loader_python() {
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/config_loader.py" "$@"
}

load_merged_config() {
    if [[ $# -ne 2 ]]; then
        echo "Error: Usage: load_merged_config <plugin_root> <project_root>" >&2
        return 1
    fi
    _config_loader_python load "$1" "$2"
}

get_config_value() {
    if [[ $# -ne 2 ]]; then
        echo "Error: Usage: get_config_value <merged_config_json> <key>" >&2
        return 1
    fi
    printf '%s' "$1" | _config_loader_python get "$2"
}
