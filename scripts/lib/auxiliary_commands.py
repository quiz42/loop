#!/usr/bin/env python3
"""Utilities for auxiliary command scripts."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class AuxiliaryCommandError(RuntimeError):
    """Raised when an auxiliary command cannot complete successfully."""


@dataclass(frozen=True)
class ConsultationResult:
    command: list[str]
    prompt: str
    stdout_path: Path
    stderr_path: Path
    command_path: Path
    output_path: Path
    metadata_path: Path


def project_root(start: Path | None = None) -> Path:
    root_start = start or Path.cwd()
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=root_start,
            text=True,
            capture_output=True,
            check=True,
        )
        return Path(result.stdout.strip())
    except (OSError, subprocess.CalledProcessError) as exc:
        raise AuxiliaryCommandError("Unable to determine the project root.") from exc


def shell_join(parts: list[str]) -> str:
    import shlex

    return " ".join(shlex.quote(part) for part in parts)


def timestamp() -> str:
    return subprocess.check_output(["date", "+%Y-%m-%d_%H-%M-%S"], text=True).strip()


def unique_id() -> str:
    random_bytes = os.urandom(4).hex()
    return f"{timestamp()}-{os.getpid()}-{random_bytes}"


def sanitize_path(path: Path) -> str:
    return "/".join(part for part in path.resolve().parts if part not in {"/"}).replace("/", "-")


def ensure_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def ensure_project_storage(project_root_path: Path, unique: str) -> tuple[Path, Path]:
    skill_dir = project_root_path / ".loop" / "skill" / unique
    ensure_directory(skill_dir)
    cache_base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    cache_dir = cache_base / "loop" / sanitize_path(project_root_path) / f"skill-{unique}"
    try:
        ensure_directory(cache_dir)
    except OSError:
        cache_dir = skill_dir / "cache"
        ensure_directory(cache_dir)
    return skill_dir, cache_dir


def write_markdown(path: Path, text: str) -> None:
    ensure_directory(path.parent)
    path.write_text(text, encoding="utf-8")


def read_text_file(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def python_date_iso() -> str:
    return subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True).strip()


def run_command(command: list[str], stdin_text: str, stdout_path: Path, stderr_path: Path, timeout: int | None = None) -> int:
    ensure_directory(stdout_path.parent)
    ensure_directory(stderr_path.parent)
    try:
        proc = subprocess.run(
            command,
            input=stdin_text,
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout_text = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr_text = exc.stderr.decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or f"Command timed out after {timeout} seconds.\n")
        stdout_path.write_text(stdout_text, encoding="utf-8")
        stderr_path.write_text(stderr_text, encoding="utf-8")
        return 124
    stdout_path.write_text(proc.stdout, encoding="utf-8")
    stderr_path.write_text(proc.stderr, encoding="utf-8")
    return proc.returncode


def _parse_common_args(argv: list[str], model_flag: str, timeout_flag: str) -> tuple[str, int, list[str]]:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument(model_flag, dest="model")
    parser.add_argument(timeout_flag, dest="timeout", type=int)
    args, remainder = parser.parse_known_intermixed_args(argv)
    return args.model, args.timeout, remainder


def consultation_prompt(question: str, extra_lines: list[str] | None = None) -> str:
    lines = list(extra_lines or [])
    if lines:
        lines.append("")
    lines.append(question.strip())
    return "\n".join(lines).strip() + "\n"


def write_result_files(result: ConsultationResult, input_text: str, tool_name: str, model: str, timeout: int, status: str, exit_code: int) -> None:
    write_markdown(
        result.output_path,
        input_text,
    )
    metadata = {
        "tool": tool_name,
        "model": model,
        "timeout": timeout,
        "status": status,
        "exit_code": exit_code,
        "command": result.command,
    }
    write_markdown(result.metadata_path, json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    write_markdown(result.command_path, shell_join(result.command) + "\n")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_existing_file(path: Path, description: str) -> None:
    if not path.exists():
        raise AuxiliaryCommandError(f"Missing {description}: {path}")


def command_available(binary: str) -> bool:
    return shutil.which(binary) is not None
