#!/usr/bin/env python3
"""Project root and path canonicalization helpers."""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path
from typing import Mapping


def canonicalize_path_prefix(path: str | os.PathLike[str]) -> str:
    """Resolve symlinks in the parent directory and keep the basename unchanged."""
    raw = os.fspath(path)
    if raw == "":
        return ""
    candidate = Path(raw).expanduser()
    try:
        return str(candidate.parent.resolve(strict=True) / candidate.name)
    except OSError:
        return raw


def canonicalize_path(path: str | os.PathLike[str]) -> str:
    """Return a real path, resolving the parent when the final path is absent."""
    raw = os.fspath(path)
    if raw == "":
        return ""
    candidate = Path(raw).expanduser()
    try:
        return str(candidate.resolve(strict=True))
    except OSError:
        return canonicalize_path_prefix(candidate)


def _git_root(cwd: str | os.PathLike[str] | None = None) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=os.fspath(cwd) if cwd is not None else None,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    return result.stdout.strip()


def resolve_project_root(
    cwd: str | os.PathLike[str] | None = None,
    env: Mapping[str, str] | None = None,
) -> Path | None:
    """Resolve the stable project root from an environment override or Git."""
    values = os.environ if env is None else env
    root = values.get("CLAUDE_PROJECT_DIR", "") or _git_root(cwd)
    if not root:
        return None
    return Path(canonicalize_path(root))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve loop project paths.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("root", help="Print the project root.")
    canonical = subparsers.add_parser("canonicalize", help="Canonicalize a path.")
    canonical.add_argument("path")
    prefix = subparsers.add_parser("canonicalize-prefix", help="Canonicalize only a path prefix.")
    prefix.add_argument("path")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "root":
        root = resolve_project_root()
        if root is None:
            return 1
        print(root)
        return 0
    if args.command == "canonicalize":
        print(canonicalize_path(args.path))
        return 0
    if args.command == "canonicalize-prefix":
        print(canonicalize_path_prefix(args.path))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
