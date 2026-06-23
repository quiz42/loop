#!/usr/bin/env python3
"""Background task helpers for hook stop logic."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
from pathlib import Path
from shutil import which
from typing import Iterable

_TASK_ID_RE = re.compile(r"<task-id>([^<]+)</task-id>")
_LOOP_DIR_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})$")


def expand_leading_tilde(path: str, home: str | None = None) -> str:
    """Expand bare ~ and ~/ paths without evaluating shell syntax."""
    if path == "~":
        return home if home is not None else os.environ.get("HOME", "")
    if path.startswith("~/"):
        base = home if home is not None else os.environ.get("HOME", "")
        return f"{base}/{path[2:]}"
    return path


def extract_transcript_path(hook_input: str) -> str:
    """Extract and expand transcript_path from JSON hook input."""
    try:
        data = json.loads(hook_input)
    except json.JSONDecodeError:
        return ""
    value = data.get("transcript_path", "")
    return expand_leading_tilde(value) if isinstance(value, str) else ""


def derive_loop_start_iso_ts(loop_dir: str | Path) -> str:
    """Convert a local timestamped loop directory name to UTC ISO format."""
    match = _LOOP_DIR_RE.match(Path(loop_dir).name)
    if not match:
        return ""
    naive = dt.datetime.strptime(
        " ".join((match.group(1), ":".join(match.groups()[1:]))),
        "%Y-%m-%d %H:%M:%S",
    )
    local = naive.astimezone()
    return local.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def derive_tasks_dir_from_transcript(transcript_path: str | Path, uid: int | None = None) -> Path | None:
    """Derive the background task output directory from a transcript path."""
    path = Path(transcript_path)
    if not path.name.endswith(".jsonl") or not path.parent.name:
        return None
    user_id = os.getuid() if uid is None else uid
    return Path("/tmp") / f"claude-{user_id}" / path.parent.name / path.stem / "tasks"


def _read_jsonl(path: Path) -> Iterable[dict]:
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                yield value


def _event_after_since(event: dict, since_ts: str) -> bool:
    timestamp = event.get("timestamp", "")
    return not since_ts or not timestamp or str(timestamp) >= since_ts


def is_bg_task_alive(task_id: str, tasks_dir: str | Path, lsof_bin: str = "lsof") -> bool:
    """Return true when a background task may still be running."""
    output_file = Path(tasks_dir) / f"{task_id}.output"
    if not output_file.is_file():
        return True
    if which(lsof_bin) is None:
        return True
    result = subprocess.run([lsof_bin, str(output_file)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def prune_dead_bg_task_ids(task_ids: Iterable[str], tasks_dir: str | Path) -> list[str]:
    """Drop task ids whose output files are present and no longer open."""
    return [task_id for task_id in task_ids if task_id and is_bg_task_alive(task_id, tasks_dir)]


def list_pending_background_task_ids(
    transcript_path: str | Path,
    since_ts: str = "",
    prune_dead: bool = True,
) -> list[str]:
    """List launched background task ids that lack terminal notifications."""
    path = Path(expand_leading_tilde(os.fspath(transcript_path)))
    if not path.is_file():
        raise FileNotFoundError(path)
    launched: set[str] = set()
    completed: set[str] = set()
    for event in _read_jsonl(path):
        result = event.get("toolUseResult")
        if isinstance(result, dict) and _event_after_since(event, since_ts):
            agent_id = result.get("agentId")
            background_id = result.get("backgroundTaskId")
            if result.get("isAsync") is True and agent_id:
                launched.add(str(agent_id))
            if background_id:
                launched.add(str(background_id))
        if event.get("type") == "system" and event.get("subtype") == "task_notification" and event.get("task_id"):
            completed.add(str(event["task_id"]))
        if event.get("type") == "queue-operation" and event.get("operation") == "enqueue":
            content = str(event.get("content", ""))
            completed.update(match.group(1) for match in _TASK_ID_RE.finditer(content))
    pending = sorted(launched - completed)
    if prune_dead:
        tasks_dir = derive_tasks_dir_from_transcript(path)
        if tasks_dir is not None:
            pending = prune_dead_bg_task_ids(pending, tasks_dir)
    return pending


def has_pending_background_tasks(transcript_path: str | Path, since_ts: str = "") -> bool:
    """Return whether a transcript still has pending background task ids."""
    try:
        return bool(list_pending_background_task_ids(transcript_path, since_ts))
    except FileNotFoundError:
        return False


def count_pending_background_tasks(transcript_path: str | Path, since_ts: str = "") -> int:
    """Return a pending background task count."""
    try:
        return len(list_pending_background_task_ids(transcript_path, since_ts))
    except FileNotFoundError:
        return 0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inspect hook background tasks.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    extract = subparsers.add_parser("extract-transcript")
    extract.add_argument("json_input")
    since = subparsers.add_parser("loop-start")
    since.add_argument("loop_dir")
    tasks = subparsers.add_parser("tasks-dir")
    tasks.add_argument("transcript_path")
    pending = subparsers.add_parser("pending")
    pending.add_argument("transcript_path")
    pending.add_argument("since_ts", nargs="?", default="")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "extract-transcript":
        print(extract_transcript_path(args.json_input))
        return 0
    if args.command == "loop-start":
        print(derive_loop_start_iso_ts(args.loop_dir))
        return 0
    if args.command == "tasks-dir":
        path = derive_tasks_dir_from_transcript(args.transcript_path)
        if path:
            print(path)
            return 0
        return 1
    if args.command == "pending":
        try:
            print("\n".join(list_pending_background_task_ids(args.transcript_path, args.since_ts)))
            return 0
        except FileNotFoundError:
            return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
