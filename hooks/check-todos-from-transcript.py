#!/usr/bin/env python3
"""Check transcript and task files for incomplete work items."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

LANE_PREFIX_PATTERN = re.compile(r"^\s*\[(mainline|blocking|queued)\](?:\s|$)", re.IGNORECASE)


def classify_lane(*parts: str) -> str:
    """Infer a task lane from content, defaulting to blocking for safety."""
    for part in parts:
        if not part:
            continue
        match = LANE_PREFIX_PATTERN.match(part)
        if match:
            return match.group(1).lower()
    return "blocking"


def extract_tool_calls_from_entry(entry: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    """Extract tool calls from supported transcript entry shapes."""
    tool_calls: list[tuple[str, dict[str, Any]]] = []
    entry_type = entry.get("type", "")
    if entry_type == "assistant":
        content = entry.get("message", {}).get("content", [])
    elif entry_type == "message":
        content = entry.get("content", [])
    else:
        content = []

    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                name = str(block.get("name", ""))
                tool_input = block.get("input", {})
                if name and isinstance(tool_input, dict):
                    tool_calls.append((name, tool_input))

    if entry_type == "tool_use":
        name = str(entry.get("name", "") or entry.get("tool_name", ""))
        tool_input = entry.get("input", {}) or entry.get("tool_input", {})
        if name and isinstance(tool_input, dict):
            tool_calls.append((name, tool_input))
    return tool_calls


def find_incomplete_todos_from_transcript(transcript_path: Path) -> list[dict[str, str]]:
    """Return incomplete TodoWrite items from the most recent todo payload."""
    if not transcript_path.exists():
        return []
    latest_todos: list[dict[str, Any]] = []
    with transcript_path.open("r", encoding="utf-8") as transcript:
        for line in transcript:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict):
                continue
            for tool_name, tool_input in extract_tool_calls_from_entry(entry):
                if tool_name == "TodoWrite" and isinstance(tool_input.get("todos"), list):
                    latest_todos = tool_input["todos"]

    incomplete: list[dict[str, str]] = []
    for todo in latest_todos:
        status = str(todo.get("status", ""))
        content = str(todo.get("content", ""))
        if status == "completed":
            continue
        lane = classify_lane(content)
        if lane == "queued":
            continue
        incomplete.append({"status": status, "content": content, "source": "todo", "lane": lane})
    return incomplete


def find_incomplete_tasks_from_directory(session_id: str, tasks_base_dir: str = "") -> list[dict[str, str]]:
    """Read incomplete task JSON files for a session."""
    tasks_dir = Path(tasks_base_dir).expanduser() / session_id if tasks_base_dir else Path.home() / ".claude" / "tasks" / session_id
    if not tasks_dir.is_dir():
        return []
    incomplete: list[dict[str, str]] = []
    for task_file in sorted(tasks_dir.glob("*.json")):
        try:
            task = json.loads(task_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if not isinstance(task, dict):
            continue
        status = str(task.get("status", "pending"))
        if status in {"completed", "deleted"}:
            continue
        subject = str(task.get("subject", ""))
        description = str(task.get("description", ""))
        lane = classify_lane(subject, description)
        if lane == "queued":
            continue
        content = subject or description or f"Task {task_file.stem}"
        incomplete.append({"status": status, "content": content, "source": "task", "task_id": task_file.stem, "lane": lane})
    return incomplete


def format_incomplete_items(items: list[dict[str, str]]) -> str:
    """Format incomplete items for hook output."""
    lines = ["INCOMPLETE_TODOS"]
    for item in items:
        status = item.get("status", "unknown")
        content = item.get("content", "")
        lane = item.get("lane", "blocking")
        if item.get("source") == "task":
            lines.append(f"  - [{status}] [{lane}] (Task #{item.get('task_id', '?')}) {content}")
        else:
            lines.append(f"  - [{status}] [{lane}] {content}")
    return "\n".join(lines)


def main() -> int:
    try:
        raw = sys.stdin.read().strip()
        if not raw:
            return 0
        hook_input = json.loads(raw)
        if not isinstance(hook_input, dict):
            raise ValueError("hook input must be an object")
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"PARSE_ERROR: {exc}", file=sys.stderr)
        return 2

    incomplete: list[dict[str, str]] = []
    session_id = str(hook_input.get("session_id", ""))
    if session_id:
        incomplete.extend(find_incomplete_tasks_from_directory(session_id, str(hook_input.get("tasks_base_dir", ""))))
    transcript_path = str(hook_input.get("transcript_path", ""))
    if transcript_path:
        incomplete.extend(find_incomplete_todos_from_transcript(Path(transcript_path).expanduser()))
    if not incomplete:
        return 0
    print(format_incomplete_items(incomplete))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
