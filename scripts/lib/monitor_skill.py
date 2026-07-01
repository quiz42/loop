#!/usr/bin/env python3
"""Skill invocation monitor for loop."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import monitor_common

_INVOCATION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:[-_].*)?$")


@dataclass(frozen=True)
class Invocation:
    """A recorded skill invocation."""

    path: Path
    tool: str
    status: str
    model: str
    effort: str
    duration: str
    started_at: str
    question: str
    monitored_file: Path | None
    cache_dir: Path | None


def _metadata(path: Path) -> dict[str, str]:
    return monitor_common.read_yaml_frontmatter(path / "metadata.md")


def _input_metadata(path: Path) -> dict[str, str]:
    input_file = path / "input.md"
    if not input_file.is_file():
        return {}
    values: dict[str, str] = {}
    for line in input_file.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^-\s+([^:]+):\s*(.*)$", line)
        if match:
            values[match.group(1).strip().lower()] = match.group(2).strip()
    return values


def invocation_tool(path: str | Path) -> str:
    """Return the tool recorded for an invocation."""
    invocation_path = Path(path)
    metadata = _metadata(invocation_path)
    if metadata.get("tool"):
        return metadata["tool"]
    input_values = _input_metadata(invocation_path)
    return input_values.get("tool", "unknown")


def question(path: str | Path) -> str:
    """Extract the first question paragraph from input.md."""
    input_file = Path(path) / "input.md"
    if not input_file.is_file():
        return "N/A"
    lines = input_file.read_text(encoding="utf-8").splitlines()
    inside = False
    for line in lines:
        if line.strip() == "## Question":
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside and line.strip():
            return line.strip()
    return "N/A"


def project_cache_dir(invocation_dir: str | Path, project_root: str | Path | None = None, env: dict[str, str] | None = None) -> Path:
    """Return the expected global cache directory for an invocation."""
    values = os.environ if env is None else env
    if project_root is None:
        try:
            root = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                text=True,
                capture_output=True,
                check=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            root = os.getcwd()
    else:
        root = str(project_root)
    sanitized = re.sub(r"-+", "-", re.sub(r"[^a-zA-Z0-9._-]", "-", root))
    cache_base = Path(values.get("XDG_CACHE_HOME") or Path(values.get("HOME", "")) / ".cache")
    return cache_base / "loop" / sanitized / f"skill-{Path(invocation_dir).name}"


def _first_existing(paths: list[Path], require_content: bool) -> Path | None:
    for path in paths:
        if path.is_file() and (not require_content or path.stat().st_size > 0):
            return path
    return None


def monitored_file(invocation_dir: str | Path, project_root: str | Path | None = None, env: dict[str, str] | None = None) -> Path | None:
    """Return the best file to display for a skill invocation."""
    path = Path(invocation_dir)
    tool = invocation_tool(path)
    prefix = "gemini-run" if tool == "gemini" else "codex-run"
    other_prefix = "codex-run" if prefix == "gemini-run" else "gemini-run"
    running = not (path / "metadata.md").is_file()
    cache_dirs = [project_cache_dir(path, project_root, env), path / "cache"]

    if running:
        for cache_dir in cache_dirs:
            result = _first_existing(
                [
                    cache_dir / f"{prefix}.log",
                    cache_dir / f"{prefix}.out",
                    cache_dir / f"{other_prefix}.log",
                    cache_dir / f"{other_prefix}.out",
                ],
                require_content=True,
            ) or _first_existing([cache_dir / f"{prefix}.log"], require_content=False)
            if result:
                return result
        return path / "input.md" if (path / "input.md").is_file() else None

    output = path / "output.md"
    if output.is_file() and output.stat().st_size > 0:
        return output
    for cache_dir in cache_dirs:
        result = _first_existing(
            [
                cache_dir / f"{prefix}.out",
                cache_dir / f"{prefix}.log",
                cache_dir / f"{other_prefix}.out",
                cache_dir / f"{other_prefix}.log",
            ],
            require_content=True,
        )
        if result:
            return result
    return output if output.is_file() else None


def list_invocation_dirs(skill_dir: str | Path = ".loop/skill", tool_filter: str = "") -> list[Path]:
    """Return valid invocation directories newest first."""
    root = Path(skill_dir)
    if not root.is_dir():
        return []
    directories = []
    for child in root.iterdir():
        if not child.is_dir() or not _INVOCATION_RE.match(child.name):
            continue
        tool = invocation_tool(child)
        if tool_filter and tool != tool_filter and not (tool == "unknown" and tool_filter == "codex"):
            continue
        directories.append(child)
    return sorted(directories, key=lambda item: item.name, reverse=True)


def count_stats(skill_dir: str | Path = ".loop/skill", tool_filter: str = "") -> dict[str, int]:
    """Count invocations by status."""
    stats = {"total": 0, "success": 0, "error": 0, "timeout": 0, "empty": 0, "running": 0}
    for directory in list_invocation_dirs(skill_dir, tool_filter):
        stats["total"] += 1
        metadata_file = directory / "metadata.md"
        if not metadata_file.is_file():
            stats["running"] += 1
            continue
        status = _metadata(directory).get("status", "unknown")
        if status == "empty_response":
            stats["empty"] += 1
        elif status in stats:
            stats[status] += 1
    return stats


def build_invocation(path: Path, project_root: str | Path | None = None, env: dict[str, str] | None = None) -> Invocation:
    """Build an invocation summary from disk files."""
    metadata = _metadata(path)
    input_values = _input_metadata(path)
    tool = metadata.get("tool") or input_values.get("tool", "unknown")
    status = metadata.get("status") or "running"
    model = metadata.get("model") or input_values.get("model", "N/A")
    effort = metadata.get("effort") or input_values.get("effort", "N/A")
    cache_dir = project_cache_dir(path, project_root, env)
    existing_cache_dir = cache_dir if cache_dir.is_dir() else None
    return Invocation(
        path=path,
        tool=tool,
        status=status,
        model=model,
        effort=effort,
        duration=metadata.get("duration", "N/A"),
        started_at=metadata.get("started_at", "N/A"),
        question=question(path),
        monitored_file=monitored_file(path, project_root, env),
        cache_dir=existing_cache_dir,
    )


def best_invocation(skill_dir: str | Path = ".loop/skill", tool_filter: str = "", project_root: str | Path | None = None) -> Invocation | None:
    """Return the newest invocation with content, or the newest invocation."""
    directories = list_invocation_dirs(skill_dir, tool_filter)
    if not directories:
        return None
    for directory in directories:
        file_path = monitored_file(directory, project_root)
        if file_path and file_path.is_file() and file_path.stat().st_size > 0:
            return build_invocation(directory, project_root)
    return build_invocation(directories[0], project_root)


def render_once(skill_dir: str | Path = ".loop/skill", tool_filter: str = "", project_root: str | Path | None = None) -> str:
    """Render a one-shot text dashboard."""
    focus = best_invocation(skill_dir, tool_filter, project_root)
    title = " Humanize Skill Monitor" + (f" [{tool_filter}]" if tool_filter else "")
    if focus is None:
        suffix = f" (filter: {tool_filter})" if tool_filter else ""
        return f"No skill invocations found in {skill_dir}{suffix}\n"

    stats = count_stats(skill_dir, tool_filter)
    lines = [
        "==========================================",
        title,
        "==========================================",
        "",
        f"Total Invocations: {stats['total']}",
        f"  Success: {stats['success']}  Error: {stats['error']}  Timeout: {stats['timeout']}  Empty: {stats['empty']}  Running: {stats['running']}",
        "",
        f"Focused: {focus.path.name}",
        f"  Tool:     {focus.tool}",
        f"  Status:   {focus.status}",
        f"  Model:    {focus.model} ({focus.effort})",
        f"  Duration: {focus.duration}",
        f"  Started:  {focus.started_at}",
        f"  Question: {focus.question}",
        f"  Cache:    {focus.cache_dir or 'not found'}",
        f"  Watching: {focus.monitored_file or 'none'}",
        "",
        "==========================================",
        " Watched Output",
        "==========================================",
        "",
    ]
    if focus.monitored_file and focus.monitored_file.is_file() and focus.monitored_file.stat().st_size > 0:
        lines.append(focus.monitored_file.read_text(encoding="utf-8"))
    elif focus.status == "running":
        lines.append("(Still running...)")
    else:
        lines.append("(No output available)")
    lines.extend(["", "==========================================", " Recent Invocations", "==========================================", ""])
    for directory in list_invocation_dirs(skill_dir, tool_filter)[:10]:
        item = build_invocation(directory, project_root)
        lines.append(f"  {directory.name:<38} [{item.tool:<6}] {item.status:<14} {item.duration:<6} {monitor_common.truncate_string(item.question, 50)}")
    lines.append("")
    lines.append("==========================================")
    return "\n".join(lines) + "\n"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Monitor loop skill invocations.")
    parser.add_argument("--skill-dir", default=".loop/skill")
    parser.add_argument("--project-root", default=None)
    parser.add_argument("--tool-filter", choices=["codex", "gemini"], default="")
    parser.add_argument("--once", action="store_true", help="Render one dashboard snapshot and exit.")
    parser.add_argument("--interval", type=float, default=2.0, help="Refresh interval for live mode.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if not Path(args.skill_dir).is_dir():
        print(f"Error: {args.skill_dir} directory not found in current directory", file=sys.stderr)
        print("Run a skill invocation first to create monitor data", file=sys.stderr)
        return 1
    if args.once:
        print(render_once(args.skill_dir, args.tool_filter, args.project_root), end="")
        return 0
    try:
        while True:
            print("\033[2J\033[H", end="")
            print(render_once(args.skill_dir, args.tool_filter, args.project_root), end="")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("Monitor stopped.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
