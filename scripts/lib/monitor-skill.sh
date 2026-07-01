#!/usr/bin/env bash
# Shell compatibility wrapper for loop skill monitoring.

_humanize_monitor_skill() {
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/monitor_skill.py" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _humanize_monitor_skill "$@"
fi
