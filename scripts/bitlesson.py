#!/usr/bin/env python3
"""Bitter Lesson workflow helpers."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
LIB_DIR = SCRIPT_DIR / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from auxiliary_commands import AuxiliaryCommandError, project_root

DEFAULT_TEMPLATE = """# Bitter Lesson Log

This file records small lessons learned from implementation deltas.

## Entries

"""


def bitlesson_dir(root: Path) -> Path:
    return root / ".loop" / "bitlesson"


def lessons_path(root: Path) -> Path:
    return bitlesson_dir(root) / "lessons.md"


def state_path(root: Path) -> Path:
    return bitlesson_dir(root) / "state.json"


def init_workflow(root: Path, force: bool = False) -> Path:
    directory = bitlesson_dir(root)
    directory.mkdir(parents=True, exist_ok=True)
    path = lessons_path(root)
    if not path.exists() or force:
        path.write_text(DEFAULT_TEMPLATE, encoding="utf-8")
    state = {"created_at": datetime.now(timezone.utc).isoformat(), "active_lesson": None}
    if not state_path(root).exists() or force:
        state_path(root).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    return path


def parse_lessons(text: str) -> list[tuple[str, str]]:
    lessons: list[tuple[str, str]] = []
    current_title: str | None = None
    current_lines: list[str] = []
    for line in text.splitlines():
        if line.startswith("### "):
            if current_title is not None:
                lessons.append((current_title, "\n".join(current_lines).strip()))
            current_title = line[4:].strip()
            current_lines = []
        elif current_title is not None:
            current_lines.append(line)
    if current_title is not None:
        lessons.append((current_title, "\n".join(current_lines).strip()))
    return lessons


def select_lesson(root: Path, query: str | None = None) -> tuple[str, str]:
    path = lessons_path(root)
    if not path.exists():
        raise AuxiliaryCommandError("Bitter Lesson workflow is not initialized. Run bitlesson-init first.")
    lessons = parse_lessons(path.read_text(encoding="utf-8"))
    if not lessons:
        raise AuxiliaryCommandError("No Bitter Lesson entries are available.")
    if query:
        query_lower = query.lower()
        for title, body in lessons:
            if query_lower in title.lower() or query_lower in body.lower():
                return title, body
        raise AuxiliaryCommandError(f"No Bitter Lesson entry matched: {query}")
    return lessons[-1]


def validate_delta(delta_path: Path) -> list[str]:
    if not delta_path.is_file():
        raise AuxiliaryCommandError(f"Delta file not found: {delta_path}")
    content = delta_path.read_text(encoding="utf-8")
    errors: list[str] = []
    if not content.strip():
        errors.append("Delta file is empty.")
    if "## Problem" not in content:
        errors.append("Delta must include a '## Problem' section.")
    if "## Change" not in content:
        errors.append("Delta must include a '## Change' section.")
    if "## Lesson" not in content:
        errors.append("Delta must include a '## Lesson' section.")
    return errors


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage Bitter Lesson workflow files.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    init = subparsers.add_parser("init")
    init.add_argument("--force", action="store_true")
    select = subparsers.add_parser("select")
    select.add_argument("query", nargs="?")
    validate = subparsers.add_parser("validate-delta")
    validate.add_argument("delta_file")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        root = project_root()
        if args.command == "init":
            path = init_workflow(root, args.force)
            print(path)
        elif args.command == "select":
            title, body = select_lesson(root, args.query)
            print(f"### {title}")
            if body:
                print(body)
        elif args.command == "validate-delta":
            errors = validate_delta(Path(args.delta_file))
            if errors:
                for error in errors:
                    print(f"Error: {error}", file=sys.stderr)
                return 1
            print("Delta is valid.")
    except AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
