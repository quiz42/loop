#!/usr/bin/env python3
"""Main command line entry point for loop."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from textwrap import dedent

SCRIPT_DIR = Path(__file__).resolve().parent
LIB_DIR = SCRIPT_DIR / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

import monitor_common
import monitor_skill

TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:[-_].*)?$")


@dataclass(frozen=True)
class LoopSession:
    """Summary of a local RLCR loop session."""

    path: Path
    state_file: Path | None
    status: str
    log_file: Path | None
    goal_tracker: Path | None


def project_root(start: Path | None = None) -> Path:
    """Return the git project root or the current working directory."""
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
    except (OSError, subprocess.CalledProcessError):
        return root_start.resolve()


def now_timestamp() -> str:
    """Return a UTC timestamp suitable for generated documents."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slugify(value: str, max_length: int = 60) -> str:
    """Convert a free-form value into a compact file-name slug."""
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value.lower()).strip("-")
    return (slug or "idea")[:max_length].strip("-") or "idea"


def ensure_parent(path: Path) -> None:
    """Create a file parent directory when needed."""
    path.parent.mkdir(parents=True, exist_ok=True)


def write_text(path: Path, content: str, force: bool = False) -> None:
    """Write text to a file, protecting existing files unless force is set."""
    if path.exists() and not force:
        raise FileExistsError(f"Refusing to overwrite existing file: {path}. Pass --force to replace it.")
    ensure_parent(path)
    path.write_text(content, encoding="utf-8")


def render_idea(description: str, title: str | None = None) -> str:
    """Render a structured idea draft from a short description."""
    clean_description = " ".join(description.strip().split())
    idea_title = title or clean_description[:80].rstrip(".") or "loop idea"
    return dedent(
        f"""
        # {idea_title}

        Generated: {now_timestamp()}

        ## Idea

        {clean_description}

        ## Target Outcome

        Define a focused change that can be reviewed through the RLCR workflow and verified with clear acceptance criteria.

        ## Users

        - Developers using loop to plan, implement, and review iterative changes.

        ## Acceptance Criteria

        - AC-1: The desired behavior is described in concrete user-facing terms.
        - AC-2: The implementation can be validated with local commands or tests.
        - AC-3: Edge cases and expected failure modes are documented before work begins.

        ## Open Questions

        - What constraints, integrations, or compatibility requirements must the plan preserve?
        - Which files or commands prove the change works?
        """
    ).lstrip()


def _read_existing_input(path: Path | None, fallback: str | None) -> str:
    if path is not None:
        if not path.is_file():
            raise FileNotFoundError(f"Input file not found: {path}")
        return path.read_text(encoding="utf-8").strip()
    if fallback:
        return fallback.strip()
    raise ValueError("Provide an idea with positional text or --input")


def _first_markdown_heading(markdown: str) -> str:
    for line in markdown.splitlines():
        if line.startswith("# "):
            return line.removeprefix("# ").strip()
    first = next((line.strip() for line in markdown.splitlines() if line.strip()), "loop plan")
    return first[:80]


def render_plan(idea_markdown: str, title: str | None = None) -> str:
    """Render a practical RLCR implementation plan from an idea document."""
    plan_title = title or _first_markdown_heading(idea_markdown)
    return dedent(
        f"""
        # {plan_title} Implementation Plan

        Generated: {now_timestamp()}

        ## Source Idea

        {idea_markdown.strip()}

        ## Goal

        Deliver the requested change in small, reviewable increments while preserving existing behavior.

        ## Scope

        - Confirm the current project structure and affected entry points.
        - Implement the smallest complete change that satisfies the acceptance criteria.
        - Add or update local tests for the changed behavior.
        - Run the documented verification command before considering the work complete.

        ## Implementation Steps

        1. Inspect the current code path and identify the minimal files to change.
        2. Add the implementation with clear error handling and stable command behavior.
        3. Add unittest coverage for success paths, invalid input, and file output behavior.
        4. Run the test suite and fix regressions before review.
        5. Summarize the completed behavior and verification result.

        ## Acceptance Criteria

        - AC-1: The command or feature behaves as described by the idea.
        - AC-2: Local tests cover the primary behavior and at least one failure path.
        - AC-3: Documentation or command help explains how to use the new behavior.

        ## Verification

        ```bash
        python3 -m unittest discover -s tests
        ```
        """
    ).lstrip()


def latest_log_file(session_dir: Path) -> Path | None:
    """Return the best log-like file for an RLCR session."""
    candidates: list[Path] = []
    for pattern in ("*.log", "*.out", "transcript*.md", "summary*.md"):
        candidates.extend(path for path in session_dir.rglob(pattern) if path.is_file())
    if not candidates:
        return None
    return max(candidates, key=lambda path: (path.stat().st_mtime, str(path)))


def latest_goal_tracker(session_dir: Path) -> Path | None:
    """Return the newest goal tracker in a session."""
    candidates = [path for path in session_dir.rglob("goal-tracker.md") if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: (path.stat().st_mtime, str(path)))


def latest_loop_session(loop_dir: Path) -> LoopSession | None:
    """Build a summary for the newest RLCR session."""
    session = monitor_common.find_latest_session(loop_dir)
    if session is None:
        return None
    state_file, status = monitor_common.find_state_file(session)
    return LoopSession(
        path=session,
        state_file=state_file,
        status=status,
        log_file=latest_log_file(session),
        goal_tracker=latest_goal_tracker(session),
    )


def render_rlcr_once(loop_dir: Path) -> str:
    """Render a one-shot RLCR monitor view."""
    session = latest_loop_session(loop_dir)
    if session is None:
        return f"No session directories found in {loop_dir}\nStart an RLCR loop first with loop start-rlcr-loop\n"

    lines = [
        "==========================================",
        " loop RLCR Monitor",
        "==========================================",
        "",
        f"Session: {session.path.name}",
        f"Status:  {session.status}",
        f"State:   {session.state_file or 'not found'}",
        f"Log:     {session.log_file or 'not found'}",
    ]
    if session.goal_tracker:
        total, completed, active, done, deferred, issues, goal = monitor_common.parse_goal_tracker(session.goal_tracker)
        lines.extend(
            [
                f"Goal:    {goal}",
                f"ACs:     {completed}/{total}",
                f"Tasks:   active {active}, completed {done}, deferred {deferred}, open issues {issues}",
            ]
        )
    lines.extend(["", "==========================================", " Recent Output", "==========================================", ""])
    if session.log_file and session.log_file.is_file() and session.log_file.stat().st_size > 0:
        content = session.log_file.read_text(encoding="utf-8", errors="replace")
        lines.append("\n".join(content.splitlines()[-80:]))
    else:
        lines.append("(No log output available yet)")
    lines.append("")
    return "\n".join(lines)


def monitor_rlcr(args: argparse.Namespace) -> int:
    """Run the RLCR monitor."""
    loop_dir = Path(args.loop_dir)
    if args.once:
        print(render_rlcr_once(loop_dir), end="")
        return 0 if latest_loop_session(loop_dir) else 1
    try:
        while True:
            print("\033[2J\033[H", end="")
            print(render_rlcr_once(loop_dir), end="")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("Monitor stopped.")
        return 0


def monitor_skill_command(tool_filter: str, args: argparse.Namespace) -> int:
    """Run the skill monitor with an optional tool filter."""
    skill_dir = Path(args.skill_dir)
    if not skill_dir.is_dir():
        print(f"Error: {skill_dir} directory not found in current directory", file=sys.stderr)
        print("Run a skill invocation first to create monitor data", file=sys.stderr)
        return 1
    if args.once:
        print(monitor_skill.render_once(skill_dir, tool_filter, args.project_root), end="")
        return 0
    try:
        while True:
            print("\033[2J\033[H", end="")
            print(monitor_skill.render_once(skill_dir, tool_filter, args.project_root), end="")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("Monitor stopped.")
        return 0


def command_gen_idea(args: argparse.Namespace) -> int:
    """Generate an idea draft."""
    description = " ".join(args.description).strip()
    if not description:
        print("Error: gen-idea requires a description", file=sys.stderr)
        return 2
    content = render_idea(description, args.title)
    output = Path(args.output) if args.output else Path("docs") / f"idea-{slugify(args.title or description)}.md"
    try:
        write_text(output, content, args.force)
    except OSError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote idea draft to {output}")
    return 0


def command_gen_plan(args: argparse.Namespace) -> int:
    """Generate an implementation plan from an idea."""
    idea_text = " ".join(args.idea).strip() if args.idea else None
    try:
        source = _read_existing_input(Path(args.input) if args.input else None, idea_text)
        content = render_plan(source, args.title)
        output = Path(args.output) if args.output else Path("docs") / f"plan-{slugify(args.title or _first_markdown_heading(source))}.md"
        write_text(output, content, args.force)
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1 if not isinstance(exc, ValueError) else 2
    print(f"Wrote implementation plan to {output}")
    return 0


def command_start_rlcr_loop(args: argparse.Namespace) -> int:
    """Create a local RLCR session directory from a plan file."""
    plan = Path(args.plan)
    if not plan.is_file():
        print(f"Error: plan file not found: {plan}", file=sys.stderr)
        return 1
    root = project_root()
    loop_root = root / ".loop" / "rlcr"
    session_name = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M-%S")
    session = loop_root / session_name
    session.mkdir(parents=True, exist_ok=False)
    state = session / "state.md"
    state.write_text(
        dedent(
            f"""
            ---
            status: active
            plan_file: {plan}
            started_at: {now_timestamp()}
            ---

            # RLCR Session

            Plan: {plan}
            Base branch: {args.base_branch}
            Max iterations: {args.max_iterations}
            Full review round: {args.full_review_round}
            """
        ).lstrip(),
        encoding="utf-8",
    )
    (session / "loop.log").write_text(f"Started RLCR loop for {plan}\n", encoding="utf-8")
    print(f"Created RLCR session at {session}")
    return 0


def command_cancel_rlcr_loop(args: argparse.Namespace) -> int:
    """Mark the newest RLCR session as cancelled."""
    session = latest_loop_session(Path(args.loop_dir))
    if session is None:
        print(f"No session directories found in {args.loop_dir}", file=sys.stderr)
        return 1
    cancelled = session.path / "cancelled-state.md"
    cancelled.write_text(
        dedent(
            f"""
            ---
            status: cancelled
            cancelled_at: {now_timestamp()}
            ---

            # Cancelled

            {args.reason}
            """
        ).lstrip(),
        encoding="utf-8",
    )
    print(f"Cancelled RLCR session {session.path.name}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the top-level argument parser."""
    parser = argparse.ArgumentParser(prog="loop", description="loop command line tools.")
    subparsers = parser.add_subparsers(dest="command")

    monitor = subparsers.add_parser("monitor", help="Monitor RLCR or skill activity.")
    monitor_sub = monitor.add_subparsers(dest="target")

    rlcr = monitor_sub.add_parser("rlcr", help="Monitor the latest RLCR loop log.")
    rlcr.add_argument("--loop-dir", default=".loop/rlcr")
    rlcr.add_argument("--once", action="store_true", help="Render one snapshot and exit.")
    rlcr.add_argument("--interval", type=float, default=2.0)
    rlcr.set_defaults(func=monitor_rlcr)

    for target, help_text, tool_filter in (
        ("skill", "Monitor all skill invocations.", ""),
        ("codex", "Monitor codex skill invocations only.", "codex"),
        ("gemini", "Monitor gemini skill invocations only.", "gemini"),
    ):
        command = monitor_sub.add_parser(target, help=help_text)
        command.add_argument("--skill-dir", default=".loop/skill")
        command.add_argument("--project-root", default=None)
        command.add_argument("--once", action="store_true", help="Render one snapshot and exit.")
        command.add_argument("--interval", type=float, default=2.0)
        command.set_defaults(func=lambda args, filter_value=tool_filter: monitor_skill_command(filter_value, args))

    idea = subparsers.add_parser("gen-idea", help="Generate a structured idea draft.")
    idea.add_argument("description", nargs="*", help="Idea description text.")
    idea.add_argument("--title", default=None)
    idea.add_argument("--output", "-o", default=None)
    idea.add_argument("--force", action="store_true")
    idea.set_defaults(func=command_gen_idea)

    plan = subparsers.add_parser("gen-plan", help="Generate an implementation plan from an idea.")
    plan.add_argument("idea", nargs="*", help="Idea text when --input is not used.")
    plan.add_argument("--input", "-i", default=None)
    plan.add_argument("--output", "-o", default=None)
    plan.add_argument("--title", default=None)
    plan.add_argument("--force", action="store_true")
    plan.set_defaults(func=command_gen_plan)

    start = subparsers.add_parser("start-rlcr-loop", help="Create a local RLCR loop session from a plan.")
    start.add_argument("plan")
    start.add_argument("--base-branch", default="main")
    start.add_argument("--max-iterations", type=int, default=10)
    start.add_argument("--full-review-round", type=int, default=5)
    start.set_defaults(func=command_start_rlcr_loop)

    cancel = subparsers.add_parser("cancel-rlcr-loop", help="Mark the newest RLCR loop session as cancelled.")
    cancel.add_argument("--loop-dir", default=".loop/rlcr")
    cancel.add_argument("--reason", default="Cancelled by user request.")
    cancel.set_defaults(func=command_cancel_rlcr_loop)

    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the command line interface."""
    parser = build_parser()
    # Default 'loop monitor [args...]' to 'loop monitor rlcr [args...]'
    # by injecting 'rlcr' as the first monitor subcommand when missing
    raw_args = list(argv) if argv is not None else sys.argv[1:]
    monitor_targets = {"rlcr", "skill", "codex", "gemini"}
    if raw_args and raw_args[0] == "monitor":
        rest = raw_args[1:]
        # If no target subcommand is provided, inject "rlcr" as default
        if not rest or rest[0] not in monitor_targets:
            raw_args = ["monitor", "rlcr"] + rest
    args = parser.parse_args(raw_args)
    if not hasattr(args, "func"):
        parser.print_help()
        return 1
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
