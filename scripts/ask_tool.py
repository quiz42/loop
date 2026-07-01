#!/usr/bin/env python3
"""One-shot query interfaces for external command line research tools."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
LIB_DIR = SCRIPT_DIR / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from auxiliary_commands import (
    AuxiliaryCommandError,
    ConsultationResult,
    command_available,
    consultation_prompt,
    ensure_project_storage,
    project_root,
    run_command,
    unique_id,
    write_markdown,
    write_result_files,
)


def _parse_question(parts: list[str]) -> str:
    question = " ".join(parts).strip()
    if not question:
        raise AuxiliaryCommandError("No question or task provided.")
    return question


def _validate_name(value: str, label: str, allow_colon: bool = False) -> None:
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    if allow_colon:
        allowed.add(":")
    if not value or any(char not in allowed for char in value):
        raise AuxiliaryCommandError(f"Invalid {label}: {value}")


def run_codex(args: argparse.Namespace) -> int:
    if not command_available("codex"):
        raise AuxiliaryCommandError("The 'codex' command is not installed or not in PATH.")
    model = args.codex_model
    effort = args.codex_effort
    if ":" in model:
        model, effort = model.split(":", 1)
    _validate_name(model, "Codex model")
    _validate_name(effort, "Codex effort")
    question = _parse_question(args.question)
    root = project_root()
    skill_dir, cache_dir = ensure_project_storage(root, unique_id())
    prompt = consultation_prompt(question)
    command = ["codex", "exec", "-m", model, "-c", f"model_reasoning_effort={effort}"]
    command.extend(["--dangerously-bypass-approvals-and-sandbox" if args.bypass_sandbox else "--full-auto", "-C", str(root), "-"])
    stdout_path = cache_dir / "codex-run.out"
    stderr_path = cache_dir / "codex-run.log"
    result = ConsultationResult(
        command=command,
        prompt=prompt,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        command_path=cache_dir / "codex-run.cmd",
        output_path=skill_dir / "output.md",
        metadata_path=skill_dir / "metadata.md",
    )
    write_markdown(skill_dir / "input.md", f"# Ask Codex Input\n\n{question}\n")
    exit_code = run_command(command, prompt, stdout_path, stderr_path, timeout=args.codex_timeout)
    output = stdout_path.read_text(encoding="utf-8")
    status = "success" if exit_code == 0 and output.strip() else "error"
    write_result_files(result, output, "codex", model, args.codex_timeout, status, exit_code)
    if status != "success":
        raise AuxiliaryCommandError(f"Codex query failed with exit code {exit_code}. Logs: {cache_dir}")
    print(output, end="")
    return 0


def run_gemini(args: argparse.Namespace) -> int:
    if not command_available("gemini"):
        raise AuxiliaryCommandError("The 'gemini' command is not installed or not in PATH.")
    _validate_name(args.gemini_model, "Gemini model")
    question = _parse_question(args.question)
    root = project_root()
    skill_dir, cache_dir = ensure_project_storage(root, unique_id())
    prompt = consultation_prompt(
        question,
        ["Use Google Search or available web research tools before answering. Cite sources when possible."],
    )
    command = ["gemini", "-m", args.gemini_model]
    command.append("--yolo" if args.yolo else "--sandbox")
    command.extend(["-o", "text", "-p", prompt])
    stdout_path = cache_dir / "gemini-run.out"
    stderr_path = cache_dir / "gemini-run.log"
    result = ConsultationResult(
        command=command,
        prompt=prompt,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        command_path=cache_dir / "gemini-run.cmd",
        output_path=skill_dir / "output.md",
        metadata_path=skill_dir / "metadata.md",
    )
    write_markdown(skill_dir / "input.md", f"# Ask Gemini Input\n\n{question}\n")
    exit_code = run_command(command, "", stdout_path, stderr_path, timeout=args.gemini_timeout)
    output = stdout_path.read_text(encoding="utf-8")
    status = "success" if exit_code == 0 and output.strip() else "error"
    write_result_files(result, output, "gemini", args.gemini_model, args.gemini_timeout, status, exit_code)
    if status != "success":
        raise AuxiliaryCommandError(f"Gemini query failed with exit code {exit_code}. Logs: {cache_dir}")
    print(output, end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run one-shot loop consultation commands.")
    subparsers = parser.add_subparsers(dest="provider", required=True)
    codex = subparsers.add_parser("codex", description="Ask Codex a one-shot question.")
    codex.add_argument("--codex-model", default="gpt-5.5")
    codex.add_argument("--codex-effort", default="high")
    codex.add_argument("--codex-timeout", type=int, default=3600)
    codex.add_argument("--bypass-sandbox", action="store_true")
    codex.add_argument("question", nargs="*")
    gemini = subparsers.add_parser("gemini", description="Ask Gemini a one-shot research question.")
    gemini.add_argument("--gemini-model", default="gemini-3.1-pro-preview")
    gemini.add_argument("--gemini-timeout", type=int, default=3600)
    gemini.add_argument("--yolo", action="store_true")
    gemini.add_argument("question", nargs="*")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.provider == "codex":
            return run_codex(args)
        if args.provider == "gemini":
            return run_gemini(args)
    except AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
