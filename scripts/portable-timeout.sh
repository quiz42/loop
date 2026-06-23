#!/usr/bin/env bash
# Cross-platform timeout helper for humanize-loop commands.

run_with_timeout() {
    local timeout_seconds="${1:-}"
    if [[ $# -lt 2 ]]; then
        echo "Error: Usage: run_with_timeout <seconds> <command> [args...]" >&2
        return 2
    fi
    shift
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/portable_timeout.py" "$timeout_seconds" -- "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_with_timeout "$@"
fi
