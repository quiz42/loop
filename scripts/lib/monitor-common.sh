#!/usr/bin/env bash
# Shell compatibility wrapper for shared loop monitor utilities.

[[ -n "${_MONITOR_COMMON_LOADED:-}" ]] && return 0 2>/dev/null || true
_MONITOR_COMMON_LOADED=1

_monitor_common_python() {
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/monitor_common.py" "$@"
}

monitor_color_green() { _monitor_common_python color green; }
monitor_color_yellow() { _monitor_common_python color yellow; }
monitor_color_cyan() { _monitor_common_python color cyan; }
monitor_color_magenta() { _monitor_common_python color magenta; }
monitor_color_red() { _monitor_common_python color red; }
monitor_color_reset() { _monitor_common_python color reset; }
monitor_color_bg() { _monitor_common_python color bg; }
monitor_color_bold() { _monitor_common_python color bold; }
monitor_color_dim() { _monitor_common_python color dim; }
monitor_color_blue() { _monitor_common_python color blue; }

monitor_get_file_size() {
    _monitor_common_python file-size "${1:-}"
}

monitor_find_latest_session() {
    _monitor_common_python latest-session "${1:-}"
}

monitor_get_status_color() {
    _monitor_common_python status-color "${1:-unknown}"
}

monitor_find_state_file() {
    _monitor_common_python state-file "${1:-}"
}

monitor_get_yaml_value() {
    _monitor_common_python yaml-value "${1:-}" "${2:-}"
}

monitor_format_timestamp() {
    _monitor_common_python format-timestamp "${1:-}"
}

monitor_truncate_string() {
    _monitor_common_python truncate "${1:-}" "${2:-0}" "${3:-end}"
}

parse_goal_tracker_issue_counts() {
    _monitor_common_python goal-issue-counts "${1:-}"
}

parse_goal_tracker() {
    _monitor_common_python goal-tracker "${1:-}"
}

monitor_setup_terminal() {
    local header_height="${1:-1}"
    clear
    printf "\033[%s;%dr" "$header_height" "$(tput lines)"
    tput cup "$header_height" 0
}

monitor_restore_terminal() {
    printf "\033[r"
    tput cup "$(tput lines)" 0
}
