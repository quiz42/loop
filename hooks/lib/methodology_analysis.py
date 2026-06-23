#!/usr/bin/env python3
"""Methodology analysis phase helpers for loop shutdown."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

try:
    from .template_loader import load_and_render_safe
except ImportError:
    from template_loader import load_and_render_safe

VALID_EXIT_REASONS = {"complete", "stop", "maxiter"}


@dataclass
class BlockResponse:
    """Structured hook block response."""

    reason: str
    system_message: str

    def to_dict(self) -> dict[str, str]:
        return {"decision": "block", "reason": self.reason, "systemMessage": self.system_message}

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2)


def _has_content(path: Path) -> bool:
    return path.is_file() and bool(path.read_text(encoding="utf-8").strip())


def enter_methodology_analysis_phase(
    loop_dir: str | Path,
    state_file: str | Path,
    template_dir: str | Path,
    exit_reason: str,
    exit_reason_description: str,
    current_round: int,
    max_iterations: int,
    privacy_mode: bool = False,
) -> BlockResponse | None:
    """Enter the methodology analysis phase and return a block response."""
    root = Path(loop_dir)
    if privacy_mode:
        return None
    if (root / "methodology-analysis-state.md").is_file() or _has_content(root / "methodology-analysis-done.md"):
        return None
    source = Path(state_file)
    target = root / "methodology-analysis-state.md"
    source.rename(target)
    (root / ".methodology-exit-reason").write_text(exit_reason, encoding="utf-8")
    (root / "methodology-analysis-done.md").touch()
    fallback = (
        "# Methodology Analysis Phase\n\n"
        f"Please analyze the development records in {root} and provide methodology improvement suggestions.\n"
        f"Write your analysis to {root / 'methodology-analysis-report.md'}.\n"
        f"When done, write a completion note to {root / 'methodology-analysis-done.md'}."
    )
    prompt = load_and_render_safe(
        template_dir,
        "claude/methodology-analysis-prompt.md",
        fallback,
        {
            "LOOP_DIR": str(root),
            "EXIT_REASON": exit_reason,
            "EXIT_REASON_DESCRIPTION": exit_reason_description,
            "CURRENT_ROUND": str(current_round),
            "MAX_ITERATIONS": str(max_iterations),
        },
    )
    return BlockResponse(prompt, "Loop: Methodology Analysis Phase - analyzing development methodology")


def complete_methodology_analysis(loop_dir: str | Path) -> Path | None:
    """Complete the methodology analysis phase if completion artifacts are valid."""
    root = Path(loop_dir)
    done_file = root / "methodology-analysis-done.md"
    report_file = root / "methodology-analysis-report.md"
    reason_file = root / ".methodology-exit-reason"
    state_file = root / "methodology-analysis-state.md"
    if not _has_content(done_file) or not _has_content(report_file) or not reason_file.is_file():
        return None
    reason = reason_file.read_text(encoding="utf-8").strip()
    if reason not in VALID_EXIT_REASONS:
        return None
    target = root / f"{reason}-state.md"
    state_file.rename(target)
    reason_file.unlink(missing_ok=True)
    return target


def block_methodology_analysis_incomplete(loop_dir: str | Path) -> BlockResponse:
    """Return a block response that asks the session to finish methodology analysis."""
    done_file = Path(loop_dir) / "methodology-analysis-done.md"
    reason = (
        "# Methodology Analysis Incomplete\n\n"
        "Please complete the methodology analysis before exiting.\n\n"
        "You need to:\n"
        "1. Review the development records from a methodology perspective\n"
        "2. Review the analysis report\n"
        "3. Optionally help file a GitHub issue\n"
        f"4. Write a completion note to: {done_file}\n\n"
        "The completion marker file must contain actual content to signal that the analysis is done."
    )
    return BlockResponse(reason, "Loop: Methodology Analysis Phase - please complete the analysis")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage methodology analysis state.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    complete = subparsers.add_parser("complete")
    complete.add_argument("loop_dir")
    block = subparsers.add_parser("block-incomplete")
    block.add_argument("loop_dir")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "complete":
        target = complete_methodology_analysis(args.loop_dir)
        if target:
            print(target)
            return 0
        return 1
    if args.command == "block-incomplete":
        print(block_methodology_analysis_incomplete(args.loop_dir).to_json())
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
