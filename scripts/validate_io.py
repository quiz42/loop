#!/usr/bin/env python3
"""Validate input and output files for planning commands."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


class IOValidationError(ValueError):
    """Raised when command input or output paths are invalid."""


def validate_input(path: Path, min_chars: int = 10) -> None:
    if not path.is_file():
        raise IOValidationError(f"Input file not found: {path}")
    content = path.read_text(encoding="utf-8")
    if len(content.strip()) < min_chars:
        raise IOValidationError(f"Input file is too short: {path}")


def validate_output(path: Path, allow_overwrite: bool = False) -> None:
    parent = path.parent if path.parent != Path("") else Path(".")
    if not parent.exists():
        raise IOValidationError(f"Output directory does not exist: {parent}")
    if path.exists() and not allow_overwrite:
        raise IOValidationError(f"Output file already exists: {path}")


def validate_markdown_sections(path: Path, sections: list[str]) -> None:
    content = path.read_text(encoding="utf-8")
    missing = [section for section in sections if section not in content]
    if missing:
        raise IOValidationError(f"Missing required sections in {path}: {', '.join(missing)}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate loop command input and output paths.")
    parser.add_argument("mode", choices=["gen-idea", "gen-plan", "refine-plan"])
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-overwrite", action="store_true")
    parser.add_argument("--check-output-content", action="store_true")
    return parser


def validate_mode(args: argparse.Namespace) -> None:
    if args.mode in {"gen-plan", "refine-plan"}:
        if args.input is None:
            raise IOValidationError(f"{args.mode} requires --input")
        validate_input(args.input)
        required = ["## Idea"] if args.mode == "gen-plan" else ["## Implementation Steps", "## Acceptance Criteria"]
        validate_markdown_sections(args.input, required)
    elif args.input is not None:
        validate_input(args.input, min_chars=3)
    if args.check_output_content:
        validate_input(args.output)
    else:
        validate_output(args.output, args.allow_overwrite)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        validate_mode(args)
    except (IOValidationError, OSError, UnicodeDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print("IO validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
