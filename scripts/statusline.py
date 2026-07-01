#!/usr/bin/env python3
"""Terminal status line rendering for loop."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path


def _git_value(args: list[str], cwd: Path) -> str:
    try:
        return subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def git_branch(cwd: str | Path = ".") -> str:
    """Return the current git branch or a short commit hash."""
    path = Path(cwd)
    return _git_value(["rev-parse", "--abbrev-ref", "HEAD"], path) or _git_value(["rev-parse", "--short", "HEAD"], path)


def git_dirty(cwd: str | Path = ".") -> bool:
    """Return whether the current repository has uncommitted changes."""
    return bool(_git_value(["status", "--porcelain"], Path(cwd)))


def render_status_line(cwd: str | Path = ".", width: int | None = None, env: dict[str, str] | None = None) -> str:
    """Render a compact status line with directory, branch, model, and loop state."""
    values = os.environ if env is None else env
    path = Path(cwd).resolve()
    branch = git_branch(path)
    branch_part = f" {branch}{'*' if git_dirty(path) else ''}" if branch else "no git"
    model = values.get("HUMANIZE_MODEL") or values.get("CODEX_MODEL") or values.get("ANTHROPIC_MODEL") or "model unset"
    loop_status = values.get("HUMANIZE_LOOP_STATUS", "idle")
    parts = [path.name or str(path), branch_part, model, loop_status]
    line = " | ".join(parts)
    target_width = width or int(values.get("COLUMNS", "0") or "0")
    if target_width > 0 and len(line) > target_width:
        return line[: max(0, target_width - 3)] + "..."
    return line


def render_from_json(payload: str, width: int | None = None) -> str:
    """Render a status line from hook-style JSON input."""
    data = json.loads(payload or "{}")
    cwd = data.get("cwd") or data.get("workspace") or "."
    env = dict(os.environ)
    for key in ("HUMANIZE_MODEL", "CODEX_MODEL", "ANTHROPIC_MODEL", "HUMANIZE_LOOP_STATUS"):
        if key in data:
            env[key] = str(data[key])
    return render_status_line(cwd, width=width, env=env)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a loop terminal status line.")
    parser.add_argument("--cwd", default=".")
    parser.add_argument("--width", type=int, default=None)
    parser.add_argument("--json", action="store_true", help="Read status context JSON from stdin.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.json:
        import sys

        print(render_from_json(sys.stdin.read(), width=args.width))
    else:
        print(render_status_line(args.cwd, width=args.width))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
