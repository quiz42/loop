#!/usr/bin/env python3
"""Install humanize-loop command assets into local tool directories."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
LIB_DIR = SCRIPT_DIR / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from auxiliary_commands import AuxiliaryCommandError


def copy_tree_contents(source: Path, destination: Path) -> list[Path]:
    if not source.exists():
        raise AuxiliaryCommandError(f"Source directory not found: {source}")
    copied: list[Path] = []
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.rglob("*"):
        if not item.is_file():
            continue
        relative = item.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
        copied.append(target)
    return copied


def install_codex_hooks(plugin_root: Path, target_dir: Path) -> list[Path]:
    copied = copy_tree_contents(plugin_root / "hooks", target_dir / "hooks")
    config_source = plugin_root / "config" / "codex-hooks.json"
    if config_source.exists():
        config_target = target_dir / "codex-hooks.json"
        shutil.copy2(config_source, config_target)
        copied.append(config_target)
    return copied


def install_skill(skill_source: Path, destination: Path) -> Path:
    if not skill_source.exists():
        raise AuxiliaryCommandError(f"Skill source not found: {skill_source}")
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / skill_source.name
    if skill_source.is_dir():
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(skill_source, target)
    else:
        shutil.copy2(skill_source, target)
    return target


def install_skills(plugin_root: Path, destination: Path, profile: str) -> list[Path]:
    copied = copy_tree_contents(plugin_root / "skills", destination)
    manifest = destination / f"humanize-{profile}-skills.json"
    manifest.write_text(
        json.dumps({"profile": profile, "installed": [str(path) for path in copied]}, indent=2) + "\n",
        encoding="utf-8",
    )
    copied.append(manifest)
    return copied


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Install humanize-loop hooks and skills.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    hooks = subparsers.add_parser("codex-hooks")
    hooks.add_argument("--plugin-root", type=Path, default=Path.cwd())
    hooks.add_argument("--target-dir", type=Path, default=Path.home() / ".codex" / "humanize")
    skill = subparsers.add_parser("skill")
    skill.add_argument("source", type=Path)
    skill.add_argument("--destination", type=Path, default=Path.home() / ".humanize" / "skills")
    for name, profile in (("skills-codex", "codex"), ("skills-kimi", "kimi")):
        sub = subparsers.add_parser(name)
        sub.set_defaults(profile=profile)
        sub.add_argument("--plugin-root", type=Path, default=Path.cwd())
        sub.add_argument("--destination", type=Path, default=Path.home() / ".humanize" / "skills")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "codex-hooks":
            copied = install_codex_hooks(args.plugin_root, args.target_dir)
        elif args.command == "skill":
            copied = [install_skill(args.source, args.destination)]
        else:
            copied = install_skills(args.plugin_root, args.destination, args.profile)
    except AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    for path in copied:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
