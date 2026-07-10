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
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

import ask_tool
import bitlesson
import install_tools
import monitor_common
import monitor_skill
import rlcr_loop
import validate_io

TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:[-_].*)?$")


@dataclass(frozen=True)
class LoopSession:
    """Summary of a local RLCR loop session."""

    path: Path
    state_file: Path | None
    status: str
    log_file: Path | None
    goal_tracker: Path | None


@dataclass(frozen=True)
class PlanComment:
    """Reviewer comment extracted from an annotated plan."""

    index: int
    marker: str
    body: str
    category: str


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


def protected_markdown_ranges(markdown: str) -> list[tuple[int, int]]:
    """Return ranges where comment markers should be ignored."""
    ranges: list[tuple[int, int]] = []
    in_fence = False
    fence_start = 0
    offset = 0
    for line in markdown.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith(("```", "~~~")):
            if in_fence:
                ranges.append((fence_start, offset + len(line)))
                in_fence = False
            else:
                fence_start = offset
                in_fence = True
        offset += len(line)
    if in_fence:
        ranges.append((fence_start, len(markdown)))

    for match in re.finditer(r"<!--.*?-->", markdown, flags=re.DOTALL):
        ranges.append(match.span())
    return ranges


def _range_is_protected(start: int, end: int, ranges: list[tuple[int, int]]) -> bool:
    return any(start < protected_end and end > protected_start for protected_start, protected_end in ranges)


def classify_plan_comment(body: str) -> str:
    """Classify a reviewer comment for the QA ledger."""
    lowered = body.lower()
    if "?" in body or any(word in lowered for word in ("clarify", "question", "whether")):
        return "question"
    if any(word in lowered for word in ("research", "investigate", "verify", "confirm")):
        return "research request"
    if any(word in lowered for word in ("add", "change", "remove", "update", "rewrite", "include")):
        return "change request"
    return "deferred decision"


def extract_plan_comments(markdown: str) -> tuple[str, list[PlanComment]]:
    """Remove reviewer comment markup and return extracted non-empty comments."""
    protected_ranges = protected_markdown_ranges(markdown)
    patterns = [
        ("CMT", re.compile(r"(?m)^[ \t]*CMT:[ \t]*\n(?P<body>.*?)(?:\n[ \t]*ENDCMT[ \t]*(?:\n|$))", re.DOTALL)),
        ("cmt", re.compile(r"<cmt>(?P<body>.*?)</cmt>", re.IGNORECASE | re.DOTALL)),
        ("comment", re.compile(r"<comment>(?P<body>.*?)</comment>", re.IGNORECASE | re.DOTALL)),
    ]
    matches: list[tuple[int, int, str, str]] = []
    for marker, pattern in patterns:
        for match in pattern.finditer(markdown):
            if _range_is_protected(match.start(), match.end(), protected_ranges):
                continue
            matches.append((match.start(), match.end(), marker, match.group("body").strip()))
    matches.sort(key=lambda item: item[0])

    refined_parts: list[str] = []
    comments: list[PlanComment] = []
    cursor = 0
    for start, end, marker, body in matches:
        if start < cursor:
            continue
        refined_parts.append(markdown[cursor:start])
        if body:
            comments.append(
                PlanComment(
                    index=len(comments) + 1,
                    marker=marker,
                    body=body,
                    category=classify_plan_comment(body),
                )
            )
        cursor = end
    refined_parts.append(markdown[cursor:])
    refined = re.sub(r"\n{3,}", "\n\n", "".join(refined_parts)).strip() + "\n"
    return refined, comments


def validate_refine_plan_content(path: Path, content: str, comments: list[PlanComment]) -> None:
    """Validate required refine-plan input content."""
    missing = [section for section in ("## Implementation Steps", "## Acceptance Criteria") if section not in content]
    if missing:
        raise ValueError(f"Missing required sections in {path}: {', '.join(missing)}")
    if not comments:
        raise ValueError(f"No reviewer comment blocks found in {path}")


def render_qa_ledger(input_path: Path, output_path: Path, comments: list[PlanComment], mode: str, alt_language: str | None) -> str:
    """Render a deterministic QA ledger for plan refinement."""
    lines = [
        f"# Plan QA Ledger: {input_path.name}",
        "",
        "## Summary",
        "",
        f"- Input plan: `{input_path}`",
        f"- Refined plan: `{output_path}`",
        f"- Comments processed: {len(comments)}",
        f"- Mode: {mode}",
    ]
    if alt_language:
        lines.append(f"- Alternate language requested: `{alt_language}`")
    lines.extend(["", "## Comment Ledger", ""])
    for comment in comments:
        lines.extend(
            [
                f"### Comment {comment.index}",
                "",
                f"- Marker: `{comment.marker}`",
                f"- Category: {comment.category}",
                "",
                comment.body,
                "",
            ]
        )

    answers = [comment for comment in comments if comment.category == "question"]
    research = [comment for comment in comments if comment.category == "research request"]
    changes = [comment for comment in comments if comment.category == "change request"]
    deferred = [comment for comment in comments if comment.category == "deferred decision"]

    lines.extend(["## Answers", ""])
    if answers:
        for comment in answers:
            lines.append(f"- Comment {comment.index}: Requires owner confirmation or direct-mode conservative handling.")
    else:
        lines.append("- No direct questions were found.")
    lines.extend(["", "## Research Findings", ""])
    if research:
        for comment in research:
            lines.append(f"- Comment {comment.index}: Research request recorded for follow-up.")
    else:
        lines.append("- No research requests were found.")
    lines.extend(["", "## Plan Changes Applied", ""])
    if changes:
        for comment in changes:
            lines.append(f"- Comment {comment.index}: Comment markup removed; requested change recorded for implementation review.")
    else:
        lines.append("- Comment markup was removed from the refined plan.")
    lines.extend(["", "## Remaining Decisions", ""])
    remaining = deferred + answers + research
    if remaining:
        for comment in remaining:
            lines.append(f"- Comment {comment.index}: {comment.category}.")
    else:
        lines.append("- No remaining decisions.")
    lines.extend(
        [
            "",
            "## Refinement Metadata",
            "",
            f"- Refined at: {now_timestamp()}",
            "- Tool: loop refine-plan",
            "",
        ]
    )
    return "\n".join(lines)


def default_qa_path(input_path: Path, qa_dir: Path) -> Path:
    """Return the QA ledger path for an input plan."""
    return qa_dir / f"{input_path.stem}-qa.md"


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
        " Loop RLCR Monitor",
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


def command_refine_plan(args: argparse.Namespace) -> int:
    """Refine an annotated plan and write a QA ledger."""
    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else input_path
    qa_dir = Path(args.qa_dir)
    qa_path = default_qa_path(input_path, qa_dir)
    mode = "discussion" if args.discussion else "direct"
    try:
        if not input_path.is_file():
            raise FileNotFoundError(f"Input file not found: {input_path}")
        content = input_path.read_text(encoding="utf-8")
        refined, comments = extract_plan_comments(content)
        validate_refine_plan_content(input_path, content, comments)
        ensure_parent(output_path)
        output_path.write_text(refined, encoding="utf-8")
        ensure_parent(qa_path)
        qa_path.write_text(render_qa_ledger(input_path, output_path, comments, mode, args.alt_language), encoding="utf-8")
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print(f"[loop] Reading annotated plan from {input_path}")
    print(f"[loop] Found {len(comments)} reviewer comment blocks")
    print(f"[loop] Wrote refined plan to {output_path}")
    print(f"[loop] Wrote QA ledger to {qa_path}")
    return 0


def command_ask_codex(args: argparse.Namespace) -> int:
    """Ask Codex through the shared consultation tool."""
    try:
        return ask_tool.run_codex(args)
    except ask_tool.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def command_ask_gemini(args: argparse.Namespace) -> int:
    """Ask Gemini through the shared consultation tool."""
    try:
        return ask_tool.run_gemini(args)
    except ask_tool.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def command_bitlesson_init(args: argparse.Namespace) -> int:
    """Initialize the Bitter Lesson workflow."""
    try:
        path = bitlesson.init_workflow(project_root(), args.force)
    except bitlesson.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print(path)
    return 0


def command_bitlesson_select(args: argparse.Namespace) -> int:
    """Select a Bitter Lesson entry."""
    try:
        title, body = bitlesson.select_lesson(project_root(), args.query)
    except bitlesson.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print(f"### {title}")
    if body:
        print(body)
    return 0


def command_bitlesson_validate_delta(args: argparse.Namespace) -> int:
    """Validate a Bitter Lesson delta file."""
    try:
        errors = bitlesson.validate_delta(Path(args.delta_file))
    except bitlesson.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(f"Error: {error}", file=sys.stderr)
        return 1
    print("Delta is valid.")
    return 0


def _print_installed_paths(paths: list[Path]) -> int:
    for path in paths:
        print(path)
    return 0


def command_install_codex_hooks(args: argparse.Namespace) -> int:
    """Install Codex hook assets."""
    try:
        return _print_installed_paths(install_tools.install_codex_hooks(args.plugin_root, args.target_dir))
    except install_tools.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def command_install_skill(args: argparse.Namespace) -> int:
    """Install one skill directory or file."""
    try:
        return _print_installed_paths([install_tools.install_skill(args.source, args.destination)])
    except install_tools.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def command_install_skills(args: argparse.Namespace) -> int:
    """Install all bundled skills for a target profile."""
    try:
        return _print_installed_paths(install_tools.install_skills(args.plugin_root, args.destination, args.profile))
    except install_tools.AuxiliaryCommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def command_validate_io(args: argparse.Namespace) -> int:
    """Validate input and output paths for planning commands."""
    try:
        validate_io.validate_mode(args)
    except (validate_io.IOValidationError, OSError, UnicodeDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print("IO validation passed.")
    return 0


def command_start_rlcr_loop(args: argparse.Namespace) -> int:
    """Create a local RLCR session directory from a plan file."""
    model = args.codex_model
    effort = args.codex_effort
    if ":" in model:
        model, effort = model.split(":", 1)
    try:
        session = rlcr_loop.setup_rlcr_loop(
            rlcr_loop.RLCRSetupOptions(
                project_root=project_root(),
                plan_file=Path(args.plan) if args.plan else None,
                max_iterations=args.max_iterations,
                codex_model=model,
                codex_effort=effort,
                codex_timeout=args.codex_timeout,
                push_every_round=args.push_every_round,
                base_branch=args.base_branch,
                full_review_round=args.full_review_round,
                skip_impl=args.skip_impl,
                ask_codex_question=not args.yolo,
                agent_teams=args.agent_teams,
                track_plan_file=args.track_plan_file,
                methodology_analysis=not args.privacy,
            )
        )
    except (rlcr_loop.RLCRError, OSError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print("RLCR loop initialized.")
    print(f"Loop directory: {session.loop_dir}")
    print(f"State file: {session.state_file}")
    print(f"Prompt file: {session.prompt_file}")
    return 0


def command_cancel_rlcr_loop(args: argparse.Namespace) -> int:
    """Mark the newest RLCR session as cancelled."""
    try:
        code, message = rlcr_loop.cancel_rlcr_loop(project_root(), force=args.force)
    except (rlcr_loop.RLCRError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 3
    if args.reason:
        message = f"{message}\nReason: {args.reason}"
    print(message)
    return code


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

    refine = subparsers.add_parser("refine-plan", help="Refine an annotated plan and write a QA ledger.")
    refine.add_argument("--input", "-i", required=True)
    refine.add_argument("--output", "-o", default=None)
    refine.add_argument("--qa-dir", default=".loop/plan_qa")
    refine.add_argument("--alt-language", default=None)
    refine_mode = refine.add_mutually_exclusive_group()
    refine_mode.add_argument("--discussion", action="store_true")
    refine_mode.add_argument("--direct", action="store_true")
    refine.set_defaults(func=command_refine_plan)

    ask_codex = subparsers.add_parser("ask-codex", help="Ask Codex a one-shot question.")
    ask_codex.add_argument("--codex-model", default="gpt-5.5")
    ask_codex.add_argument("--codex-effort", default="high")
    ask_codex.add_argument("--codex-timeout", type=int, default=3600)
    ask_codex.add_argument("--bypass-sandbox", action="store_true")
    ask_codex.add_argument("question", nargs="*")
    ask_codex.set_defaults(func=command_ask_codex)

    ask_gemini = subparsers.add_parser("ask-gemini", help="Ask Gemini a one-shot research question.")
    ask_gemini.add_argument("--gemini-model", default="gemini-3.1-pro-preview")
    ask_gemini.add_argument("--gemini-timeout", type=int, default=3600)
    ask_gemini.add_argument("--yolo", action="store_true")
    ask_gemini.add_argument("question", nargs="*")
    ask_gemini.set_defaults(func=command_ask_gemini)

    bitlesson_parser = subparsers.add_parser("bitlesson", help="Manage Bitter Lesson workflow files.")
    bitlesson_sub = bitlesson_parser.add_subparsers(dest="bitlesson_command")

    bitlesson_init = bitlesson_sub.add_parser("init", help="Initialize the Bitter Lesson workflow.")
    bitlesson_init.add_argument("--force", action="store_true")
    bitlesson_init.set_defaults(func=command_bitlesson_init)

    bitlesson_select = bitlesson_sub.add_parser("select", help="Select a Bitter Lesson entry.")
    bitlesson_select.add_argument("query", nargs="?")
    bitlesson_select.set_defaults(func=command_bitlesson_select)

    bitlesson_validate = bitlesson_sub.add_parser("validate-delta", help="Validate a Bitter Lesson delta file.")
    bitlesson_validate.add_argument("delta_file")
    bitlesson_validate.set_defaults(func=command_bitlesson_validate_delta)

    install = subparsers.add_parser("install", help="Install loop hooks and skills.")
    install_sub = install.add_subparsers(dest="install_command")

    install_hooks = install_sub.add_parser("codex-hooks", help="Install Codex hook assets.")
    install_hooks.add_argument("--plugin-root", type=Path, default=Path.cwd())
    install_hooks.add_argument("--target-dir", type=Path, default=Path.home() / ".codex" / "loop")
    install_hooks.set_defaults(func=command_install_codex_hooks)

    install_skill = install_sub.add_parser("skill", help="Install one skill directory or file.")
    install_skill.add_argument("source", type=Path)
    install_skill.add_argument("--destination", type=Path, default=Path.home() / ".loop" / "skills")
    install_skill.set_defaults(func=command_install_skill)

    for name, profile in (("skills-codex", "codex"), ("skills-kimi", "kimi")):
        install_skills = install_sub.add_parser(name, help=f"Install bundled skills for {profile}.")
        install_skills.set_defaults(func=command_install_skills, profile=profile)
        install_skills.add_argument("--plugin-root", type=Path, default=Path.cwd())
        install_skills.add_argument("--destination", type=Path, default=Path.home() / ".loop" / "skills")

    validate = subparsers.add_parser("validate", help="Validate loop planning command inputs and outputs.")
    validate_sub = validate.add_subparsers(dest="validate_command")

    for name in ("gen-idea", "gen-plan", "refine-plan"):
        validate_command = validate_sub.add_parser(name, help=f"Validate {name} command input and output files.")
        validate_command.add_argument("--input", type=Path)
        validate_command.add_argument("--output", type=Path, required=True)
        validate_command.add_argument("--allow-overwrite", action="store_true")
        validate_command.add_argument("--check-output-content", action="store_true")
        validate_command.set_defaults(func=command_validate_io, mode=name)

    start = subparsers.add_parser("start-rlcr-loop", help="Create a local RLCR loop session from a plan.")
    start.add_argument("plan", nargs="?")
    start.add_argument("--base-branch", default=None)
    start.add_argument("--max-iterations", type=int, default=rlcr_loop.DEFAULT_MAX_ITERATIONS)
    start.add_argument("--codex-model", default=rlcr_loop.DEFAULT_CODEX_MODEL)
    start.add_argument("--codex-effort", default=rlcr_loop.DEFAULT_CODEX_EFFORT)
    start.add_argument("--codex-timeout", type=int, default=rlcr_loop.DEFAULT_CODEX_TIMEOUT)
    start.add_argument("--full-review-round", type=int, default=rlcr_loop.DEFAULT_FULL_REVIEW_ROUND)
    start.add_argument("--push-every-round", action="store_true")
    start.add_argument("--agent-teams", action="store_true")
    start.add_argument("--track-plan-file", action="store_true")
    start.add_argument("--skip-impl", action="store_true")
    start.add_argument("--yolo", action="store_true")
    start.add_argument("--privacy", action="store_true")
    start.set_defaults(func=command_start_rlcr_loop)

    cancel = subparsers.add_parser("cancel-rlcr-loop", help="Mark the newest RLCR loop session as cancelled.")
    cancel.add_argument("--loop-dir", default=".loop/rlcr")
    cancel.add_argument("--reason", default="Cancelled by user request.")
    cancel.add_argument("--force", action="store_true")
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
