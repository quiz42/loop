#!/usr/bin/env python3
"""Shared monitor helpers for humanize-loop."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Iterable

ANSI_COLORS = {
    "green": "\033[1;32m",
    "yellow": "\033[1;33m",
    "cyan": "\033[1;36m",
    "magenta": "\033[1;35m",
    "red": "\033[1;31m",
    "reset": "\033[0m",
    "bg": "\033[44m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "blue": "\033[1;34m",
}

_SESSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:[-_].*)?$")
_STATE_PRIORITY = ("methodology-analysis-state.md", "state.md")
_STATUS_COLORS = {
    "active": ANSI_COLORS["green"],
    "methodology-analysis": ANSI_COLORS["green"],
    "completed": ANSI_COLORS["cyan"],
    "failed": ANSI_COLORS["red"],
    "error": ANSI_COLORS["red"],
    "timeout": ANSI_COLORS["red"],
    "cancelled": ANSI_COLORS["yellow"],
    "max-iterations": ANSI_COLORS["red"],
    "unknown": ANSI_COLORS["dim"],
}


def color(name: str) -> str:
    """Return an ANSI color sequence by name."""
    return ANSI_COLORS.get(name, "")


def file_size(path: str | Path) -> int:
    """Return a file size in bytes, or zero when the path is missing."""
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0


def is_timestamped_directory(path: Path) -> bool:
    """Return whether a directory name starts with the monitor timestamp format."""
    return path.is_dir() and bool(_SESSION_RE.match(path.name))


def list_timestamped_directories(directory: str | Path) -> list[Path]:
    """List timestamp-named child directories newest first."""
    root = Path(directory)
    if not root.is_dir():
        return []
    return sorted(
        (child for child in root.iterdir() if is_timestamped_directory(child)),
        key=lambda child: child.name,
        reverse=True,
    )


def find_latest_session(directory: str | Path) -> Path | None:
    """Return the newest timestamp-named child directory."""
    directories = list_timestamped_directories(directory)
    return directories[0] if directories else None


def status_color(status: str) -> str:
    """Return a color sequence for a loop or invocation status."""
    return _STATUS_COLORS.get(status, ANSI_COLORS["yellow"])


def find_state_file(session_dir: str | Path) -> tuple[Path | None, str]:
    """Find the state file for a session and return the file plus status."""
    session_path = Path(session_dir)
    if not session_path.is_dir():
        return None, "unknown"
    for name in _STATE_PRIORITY:
        candidate = session_path / name
        if candidate.is_file():
            status = "methodology-analysis" if name.startswith("methodology") else "active"
            return candidate, status
    stop_files = sorted(session_path.glob("*-state.md"))
    if stop_files:
        state_file = stop_files[0]
        return state_file, state_file.name.removesuffix("-state.md")
    return None, "unknown"


def read_yaml_frontmatter(path: str | Path) -> dict[str, str]:
    """Read simple key-value YAML frontmatter from a Markdown file."""
    file_path = Path(path)
    if not file_path.is_file():
        return {}
    lines = file_path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    values: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"\'')
    return values


def yaml_value(key: str, path: str | Path) -> str:
    """Return one frontmatter value, or an empty string when absent."""
    return read_yaml_frontmatter(path).get(key, "")


def format_timestamp(timestamp: str) -> str:
    """Format an ISO timestamp for compact terminal display."""
    if not timestamp or timestamp == "N/A":
        return "N/A"
    return timestamp.replace("T", " ").replace("Z", " UTC")


def truncate_string(value: str, max_length: int, direction: str = "end") -> str:
    """Truncate a string with an ellipsis at the requested side."""
    if max_length <= 0:
        return ""
    if len(value) <= max_length:
        return value
    if max_length <= 3:
        return "." * max_length
    if direction == "start":
        return "..." + value[-(max_length - 3) :]
    return value[: max_length - 3] + "..."


def _section_lines(lines: list[str], start_heading: str, stop_prefix: str) -> list[str]:
    collecting = False
    result: list[str] = []
    for line in lines:
        if line.strip().startswith(start_heading):
            collecting = True
            result.append(line)
            continue
        if collecting and line.startswith(stop_prefix) and not line.strip().startswith(start_heading):
            break
        if collecting:
            result.append(line)
    return result


def _table_data_rows(lines: Iterable[str]) -> list[str]:
    rows = [line for line in lines if line.startswith("|")]
    return rows[2:] if len(rows) > 2 else []


def parse_goal_tracker_issue_counts(path: str | Path) -> tuple[int, int, int]:
    """Return blocking, queued, and total open issue counts from a goal tracker."""
    file_path = Path(path)
    if not file_path.is_file():
        return 0, 0, 0
    lines = file_path.read_text(encoding="utf-8").splitlines()
    blocking = len(_table_data_rows(_section_lines(lines, "### Blocking Side Issues", "###")))
    queued = len(_table_data_rows(_section_lines(lines, "### Queued Side Issues", "###")))
    open_issues = blocking + queued
    if open_issues == 0:
        open_issues = len(_table_data_rows(_section_lines(lines, "### Open Issues", "###")))
        blocking = open_issues
    return blocking, queued, open_issues


def parse_goal_tracker(path: str | Path) -> tuple[int, int, int, int, int, int, str]:
    """Summarize a goal tracker Markdown file."""
    file_path = Path(path)
    if not file_path.is_file():
        return 0, 0, 0, 0, 0, 0, "No goal tracker"
    lines = file_path.read_text(encoding="utf-8").splitlines()
    ac_section = _section_lines(lines, "### Acceptance Criteria", "##")
    total_acs = sum(
        1 for line in ac_section if re.match(r"^(\|\s*\*{0,2}AC-?\d+|-\s*\*{0,2}AC-?\d+)", line)
    )
    active_rows = _table_data_rows(_section_lines(lines, "#### Active Tasks", "###"))
    completed_in_active = sum(1 for row in active_rows if re.search(r"\|\s*completed\s*\|", row, re.I))
    deferred_in_active = sum(1 for row in active_rows if re.search(r"\|\s*deferred\s*\|", row, re.I))
    active_tasks = max(0, len(active_rows) - completed_in_active - deferred_in_active)
    completed_rows = _table_data_rows(_section_lines(lines, "### Completed and Verified", "###"))
    completed_tasks = len(completed_rows)
    completed_acs = len({match.group(1).upper() for row in completed_rows if (match := re.match(r"\|\s*(AC-?\d+)", row))})
    deferred_tasks = len(_table_data_rows(_section_lines(lines, "### Explicitly Deferred", "###")))
    open_issues = parse_goal_tracker_issue_counts(file_path)[2]
    goal_section = _section_lines(lines, "### Ultimate Goal", "###")
    goal_summary = "No goal defined"
    for line in goal_section[1:]:
        stripped = line.strip()
        if stripped and not stripped.startswith("[To be"):
            goal_summary = stripped[:60]
            break
    return total_acs, completed_acs, active_tasks, completed_tasks, deferred_tasks, open_issues, goal_summary


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Shared humanize-loop monitor utilities.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    color_parser = subparsers.add_parser("color")
    color_parser.add_argument("name")

    size_parser = subparsers.add_parser("file-size")
    size_parser.add_argument("path")

    latest_parser = subparsers.add_parser("latest-session")
    latest_parser.add_argument("directory")

    status_parser = subparsers.add_parser("status-color")
    status_parser.add_argument("status")

    state_parser = subparsers.add_parser("state-file")
    state_parser.add_argument("session_dir")

    yaml_parser = subparsers.add_parser("yaml-value")
    yaml_parser.add_argument("key")
    yaml_parser.add_argument("path")

    timestamp_parser = subparsers.add_parser("format-timestamp")
    timestamp_parser.add_argument("timestamp")

    truncate_parser = subparsers.add_parser("truncate")
    truncate_parser.add_argument("value")
    truncate_parser.add_argument("max_length", type=int)
    truncate_parser.add_argument("direction", nargs="?", default="end")

    issues_parser = subparsers.add_parser("goal-issue-counts")
    issues_parser.add_argument("path")

    tracker_parser = subparsers.add_parser("goal-tracker")
    tracker_parser.add_argument("path")

    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "color":
        print(color(args.name), end="")
    elif args.command == "file-size":
        print(file_size(args.path))
    elif args.command == "latest-session":
        print(find_latest_session(args.directory) or "")
    elif args.command == "status-color":
        print(status_color(args.status), end="")
    elif args.command == "state-file":
        state_file, state = find_state_file(args.session_dir)
        print(f"{state_file or ''}|{state}")
    elif args.command == "yaml-value":
        print(yaml_value(args.key, args.path))
    elif args.command == "format-timestamp":
        print(format_timestamp(args.timestamp))
    elif args.command == "truncate":
        print(truncate_string(args.value, args.max_length, args.direction))
    elif args.command == "goal-issue-counts":
        print("|".join(str(part) for part in parse_goal_tracker_issue_counts(args.path)))
    elif args.command == "goal-tracker":
        print("|".join(str(part) for part in parse_goal_tracker(args.path)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
