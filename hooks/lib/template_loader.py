#!/usr/bin/env python3
"""Prompt template loading and single-pass rendering."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable, Mapping

_PLACEHOLDER_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
_REQUIRED_SUBDIRS = ("block", "codex", "claude", "plan")


class TemplateError(ValueError):
    """Raised when a template operation cannot be completed."""


def get_template_dir(script_dir: str | Path) -> Path:
    """Return the prompt-template directory relative to hooks/lib."""
    return Path(script_dir).resolve().parents[1] / "prompt-template"


def _safe_template_path(template_dir: str | Path, template_name: str) -> Path:
    root = Path(template_dir).resolve()
    candidate = (root / template_name).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise TemplateError(f"Template path escapes template directory: {template_name}") from exc
    return candidate


def load_template(template_dir: str | Path, template_name: str) -> str:
    """Load a template by name, returning an empty string when it is missing."""
    path = _safe_template_path(template_dir, template_name)
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8")


def _coerce_variables(variables: Mapping[str, object] | Iterable[str] | None) -> dict[str, str]:
    values: dict[str, str] = {}
    if variables is None:
        return values
    if isinstance(variables, Mapping):
        return {str(key): str(value) for key, value in variables.items()}
    for assignment in variables:
        key, sep, value = str(assignment).partition("=")
        if sep:
            values[key] = value
    return values


def render_template(
    content: str,
    variables: Mapping[str, object] | Iterable[str] | None = None,
    **kwargs: object,
) -> str:
    """Render {{NAME}} placeholders in one pass while leaving missing names intact."""
    values = _coerce_variables(variables)
    values.update({str(key): str(value) for key, value in kwargs.items()})

    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        return values.get(key, match.group(0))

    return _PLACEHOLDER_RE.sub(replace, content)


def load_and_render(
    template_dir: str | Path,
    template_name: str,
    variables: Mapping[str, object] | Iterable[str] | None = None,
) -> str:
    """Load and render a template, returning an empty string when missing."""
    content = load_template(template_dir, template_name)
    return render_template(content, variables) if content else ""


def append_template(base_content: str, template_dir: str | Path, template_name: str) -> str:
    """Append another template if it exists and has content."""
    additional = load_template(template_dir, template_name)
    if not additional:
        return base_content
    return f"{base_content}\n{additional}"


def load_and_render_safe(
    template_dir: str | Path,
    template_name: str,
    fallback_message: str,
    variables: Mapping[str, object] | Iterable[str] | None = None,
) -> str:
    """Load and render a template, falling back to a rendered inline message."""
    try:
        result = load_and_render(template_dir, template_name, variables)
    except (OSError, TemplateError):
        result = ""
    return result if result else render_template(fallback_message, variables)


def validate_template_dir(template_dir: str | Path) -> tuple[bool, list[str]]:
    """Return whether a template directory has the expected layout."""
    root = Path(template_dir)
    if not root.is_dir():
        return False, list(_REQUIRED_SUBDIRS)
    missing = [name for name in _REQUIRED_SUBDIRS if not (root / name).is_dir()]
    return not missing, missing


def _parse_variables(items: list[str]) -> dict[str, str]:
    return dict(item.split("=", 1) for item in items if "=" in item)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load and render prompt templates.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    directory = subparsers.add_parser("template-dir")
    directory.add_argument("script_dir")
    load = subparsers.add_parser("load")
    load.add_argument("template_dir")
    load.add_argument("template_name")
    render = subparsers.add_parser("render")
    render.add_argument("assignments", nargs="*")
    load_render = subparsers.add_parser("load-render")
    load_render.add_argument("template_dir")
    load_render.add_argument("template_name")
    load_render.add_argument("assignments", nargs="*")
    validate = subparsers.add_parser("validate")
    validate.add_argument("template_dir")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "template-dir":
        print(get_template_dir(args.script_dir))
        return 0
    if args.command == "load":
        content = load_template(args.template_dir, args.template_name)
        if content:
            print(content, end="")
        return 0 if content else 1
    if args.command == "render":
        print(render_template(sys.stdin.read(), _parse_variables(args.assignments)), end="")
        return 0
    if args.command == "load-render":
        content = load_and_render(args.template_dir, args.template_name, _parse_variables(args.assignments))
        if content:
            print(content, end="")
        return 0 if content else 1
    if args.command == "validate":
        valid, missing = validate_template_dir(args.template_dir)
        if not valid:
            print(f"Missing template directories: {' '.join(missing)}", file=sys.stderr)
        return 0 if valid else 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
