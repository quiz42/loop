#!/usr/bin/env python3
"""RLCR loop orchestration utilities for loop."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from textwrap import dedent

DEFAULT_CODEX_MODEL = "gpt-5.5"
DEFAULT_CODEX_EFFORT = "high"
DEFAULT_CODEX_TIMEOUT = 5400
DEFAULT_MAX_ITERATIONS = 42
DEFAULT_FULL_REVIEW_ROUND = 5
ALLOWED_EFFORTS = {"xhigh", "high", "medium", "low"}
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
SESSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:[-_].*)?$")


class RLCRError(RuntimeError):
    """Raised when an RLCR operation cannot complete."""


@dataclass(frozen=True)
class RLCRSetupOptions:
    """Configuration used to create a loop session."""

    project_root: Path
    plan_file: Path | None
    max_iterations: int = DEFAULT_MAX_ITERATIONS
    codex_model: str = DEFAULT_CODEX_MODEL
    codex_effort: str = DEFAULT_CODEX_EFFORT
    codex_timeout: int = DEFAULT_CODEX_TIMEOUT
    push_every_round: bool = False
    base_branch: str | None = None
    full_review_round: int = DEFAULT_FULL_REVIEW_ROUND
    skip_impl: bool = False
    ask_codex_question: bool = True
    agent_teams: bool = False
    track_plan_file: bool = False
    allow_empty_bitlesson_none: bool = False
    require_bitlesson_entry_for_none: bool = False
    methodology_analysis: bool = True


@dataclass(frozen=True)
class RLCRSession:
    """Created loop session paths."""

    loop_dir: Path
    state_file: Path
    goal_tracker_file: Path
    prompt_file: Path
    summary_file: Path
    contract_file: Path


def run_git(project_root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Run a git command in the project root."""
    return subprocess.run(
        ["git", *args],
        cwd=project_root,
        text=True,
        capture_output=True,
        check=check,
    )


def resolve_project_root(start: Path | None = None, env: dict[str, str] | None = None) -> Path:
    """Resolve the project root from an override, environment, git, or current directory."""
    values = os.environ if env is None else env
    if values.get("CLAUDE_PROJECT_DIR"):
        return Path(values["CLAUDE_PROJECT_DIR"]).expanduser().resolve()
    search = Path.cwd() if start is None else Path(start)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=search,
            text=True,
            capture_output=True,
            check=True,
        )
        return Path(result.stdout.strip()).resolve()
    except (OSError, subprocess.CalledProcessError):
        return search.resolve()


def parse_state(path: Path) -> dict[str, str]:
    """Read simple key-value state from an RLCR state file."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if ":" not in line or line.lstrip().startswith("#"):
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"\'')
    return values


def active_loop_base(project_root: Path) -> Path:
    """Return the RLCR loop base directory for a project."""
    return project_root / ".loop" / "rlcr"


def find_active_loop(loop_base: Path) -> Path | None:
    """Return the newest timestamped loop directory that still has an active state."""
    if not loop_base.is_dir():
        return None
    candidates = sorted(
        (child for child in loop_base.iterdir() if child.is_dir() and SESSION_RE.match(child.name)),
        key=lambda child: child.name,
        reverse=True,
    )
    for candidate in candidates:
        if any((candidate / name).is_file() for name in ("state.md", "methodology-analysis-state.md", "finalize-state.md")):
            return candidate
    return None


def _positive_int(value: str, option: str, minimum: int = 1) -> int:
    if not value.isdigit() or int(value) < minimum:
        raise RLCRError(f"{option} must be an integer greater than or equal to {minimum}.")
    return int(value)


def _validate_safe(value: str, label: str, pattern: re.Pattern[str] = SAFE_NAME_RE) -> None:
    if not pattern.match(value):
        raise RLCRError(f"{label} contains unsupported characters: {value}")


def _ensure_git_repository(project_root: Path) -> None:
    try:
        run_git(project_root, "rev-parse", "--git-dir")
        run_git(project_root, "rev-parse", "--verify", "HEAD")
    except (OSError, subprocess.CalledProcessError) as exc:
        raise RLCRError("Project must be a git repository with at least one commit.") from exc


def _ensure_clean_tree(project_root: Path) -> None:
    result = run_git(project_root, "status", "--porcelain", "--untracked-files=all")
    if result.stdout.strip():
        raise RLCRError("Git working tree is not clean. Commit, stash, or remove changes before starting an RLCR loop.")


def _current_branch(project_root: Path) -> str:
    result = run_git(project_root, "rev-parse", "--abbrev-ref", "HEAD")
    branch = result.stdout.strip()
    _validate_safe(branch, "Current branch")
    return branch


def _branch_exists(project_root: Path, branch: str) -> bool:
    result = run_git(project_root, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}", check=False)
    return result.returncode == 0


def determine_base_branch(project_root: Path, explicit: str | None = None) -> str:
    """Choose a local base branch suitable for code review."""
    if explicit:
        _validate_safe(explicit, "Base branch")
        if not _branch_exists(project_root, explicit):
            raise RLCRError(f"Specified base branch does not exist locally: {explicit}")
        return explicit
    for candidate in ("main", "master"):
        if _branch_exists(project_root, candidate):
            return candidate
    current = _current_branch(project_root)
    if _branch_exists(project_root, current):
        return current
    raise RLCRError("Cannot determine a local base branch for code review.")


def _normalize_plan_file(project_root: Path, plan_file: Path | None) -> tuple[Path | None, Path | None]:
    if plan_file is None:
        return None, None
    raw = Path(plan_file).expanduser()
    absolute = raw if raw.is_absolute() else project_root / raw
    absolute = absolute.resolve()
    try:
        relative = absolute.relative_to(project_root)
    except ValueError as exc:
        raise RLCRError("Plan file must be inside the project root.") from exc
    if not absolute.is_file():
        raise RLCRError(f"Plan file not found: {relative}")
    content_lines = [line for line in absolute.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if len(content_lines) < 3:
        raise RLCRError("Plan file has insufficient content for an RLCR loop.")
    return absolute, relative


def _extract_section(markdown: str, headings: tuple[str, ...], max_lines: int = 10) -> str:
    lines = markdown.splitlines()
    heading_re = re.compile(r"^##\s*(.+?)\s*$")
    collecting = False
    collected: list[str] = []
    for line in lines:
        match = heading_re.match(line)
        if match:
            title = match.group(1).strip().lower()
            if collecting:
                break
            collecting = any(title.startswith(heading) for heading in headings)
            continue
        if collecting and line.strip():
            collected.append(line.rstrip())
            if len(collected) >= max_lines:
                break
    return "\n".join(collected).strip()


def extract_plan_goal(plan_path: Path | None) -> str:
    """Extract a concise goal from a Markdown plan."""
    if plan_path is None or not plan_path.is_file():
        return "Pass code review for the current branch without regressing existing behavior."
    markdown = plan_path.read_text(encoding="utf-8")
    section = _extract_section(markdown, ("goal", "objective", "purpose"))
    if section:
        return section
    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    return "Preserve the original plan scope while completing the requested implementation."


def extract_acceptance_criteria(plan_path: Path | None) -> str:
    """Extract acceptance criteria from a Markdown plan when present."""
    if plan_path is None or not plan_path.is_file():
        return "- AC-1: All blocking review findings are resolved.\n- AC-2: Existing behavior remains covered by local verification."
    markdown = plan_path.read_text(encoding="utf-8")
    section = _extract_section(markdown, ("acceptance criteria", "criteria"), max_lines=20)
    if section:
        return section
    return "- AC-1: The implementation follows the plan scope.\n- AC-2: Local verification passes before review."


def _timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d_%H-%M-%S")


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def render_state(options: RLCRSetupOptions, plan_relative: Path | None, start_branch: str, base_branch: str, base_commit: str) -> str:
    """Render the primary RLCR state file."""
    plan_value = str(plan_relative) if plan_relative is not None else ""
    values = {
        "current_round": "0",
        "max_iterations": str(options.max_iterations),
        "codex_model": options.codex_model,
        "codex_effort": options.codex_effort,
        "codex_timeout": str(options.codex_timeout),
        "push_every_round": str(options.push_every_round).lower(),
        "full_review_round": str(options.full_review_round),
        "plan_file": plan_value,
        "start_branch": start_branch,
        "base_branch": base_branch,
        "base_commit": base_commit,
        "review_started": str(options.skip_impl).lower(),
        "ask_codex_question": str(options.ask_codex_question).lower(),
        "session_id": "",
        "skip_impl": str(options.skip_impl).lower(),
        "agent_teams": str(options.agent_teams).lower(),
        "bitlesson_required": str(not options.skip_impl).lower(),
        "methodology_analysis": str(options.methodology_analysis).lower(),
        "status": "active",
    }
    lines = ["---", *[f"{key}: {value}" for key, value in values.items()], "---", ""]
    return "\n".join(lines)


def render_goal_tracker(options: RLCRSetupOptions, plan_path: Path | None, plan_relative: Path | None) -> str:
    """Render the initial goal tracker file."""
    goal = extract_plan_goal(plan_path)
    criteria = extract_acceptance_criteria(plan_path)
    source = str(plan_relative) if plan_relative is not None else "No plan file provided"
    if options.skip_impl:
        heading = "Goal Tracker (Skip Implementation Mode)"
        purpose = "This loop starts in review mode and uses the current branch as the review target."
    else:
        heading = "Goal Tracker"
        purpose = "This file keeps the loop anchored to the main objective, acceptance criteria, and round scope."
    return dedent(
        f"""
        # {heading}

        {purpose}

        ## Immutable Section

        ### Ultimate Goal
        {goal}

        ### Acceptance Criteria
        {criteria}

        ### Source Plan
        {source}

        ## Mutable Section

        ### Plan Version: 1 (Updated: Round 0)
        | Round | Change | Reason | Impact on AC |
        | - | - | - | - |
        | 0 | Loop initialized | Starting RLCR session | Establishes review anchor |

        #### Active Tasks
        | Task | Acceptance Criteria | Status | Tag | Owner | Notes |
        | - | - | - | - | - | - |
        | Define the first round objective from the plan | AC-1 | pending | coding | developer | Mainline task only |

        ### Blocking Side Issues
        | Issue | Discovered Round | Blocking AC | Resolution Path |
        | - | - | - | - |

        ### Queued Side Issues
        | Issue | Discovered Round | Why Not Blocking | Revisit Trigger |
        | - | - | - | - |

        ### Completed and Verified
        | AC | Task | Completed Round | Verified Round | Evidence |
        | - | - | - | - | - |
        """
    ).lstrip()


def render_summary_template() -> str:
    """Render the round zero summary scaffold."""
    return dedent(
        """
        # Round 0 Summary

        ## Work Completed
        - Describe completed mainline tasks.

        ## Acceptance Criteria Evidence
        - Link each completed task to an acceptance criterion and local verification result.

        ## Open Blocking Issues
        - List only issues that block the current round objective.

        ## Queued Follow-up
        - List non-blocking work that should not replace the round objective.

        ## Ready for Review
        - State whether this round is ready for review and why.
        """
    ).lstrip()


def render_round_contract(options: RLCRSetupOptions, plan_relative: Path | None) -> str:
    """Render the initial round contract."""
    anchor = f"@{plan_relative}" if plan_relative is not None else "the current branch"
    objective = "Run code review for the current branch" if options.skip_impl else f"Implement the next focused slice from {anchor}"
    return dedent(
        f"""
        # Round 0 Contract

        - Mainline Objective: {objective}.
        - Blocking Side Issues In Scope: Issues that prevent the mainline objective or acceptance criteria from passing.
        - Queued Side Issues Out of Scope: Cleanup, refactors, or future improvements that do not block acceptance.
        - Success Criteria: Summary and goal tracker show completed work with local verification evidence.
        """
    ).lstrip()


def render_prompt(options: RLCRSetupOptions, plan_path: Path | None, plan_relative: Path | None, session: RLCRSession | None = None) -> str:
    """Render the first prompt used by the loop."""
    plan_text = ""
    if plan_path is not None and plan_path.is_file():
        plan_text = plan_path.read_text(encoding="utf-8").strip()
    mode = "Code Review Only" if options.skip_impl else "Implementation and Review"
    push_note = "Push commits after each round." if options.push_every_round else "Keep round commits local unless your workflow requires pushing."
    plan_ref = f"@{plan_relative}" if plan_relative is not None else "the current branch"
    body = dedent(
        f"""
        # RLCR Round 0 Prompt

        ## Mode
        {mode}

        ## Required First Steps
        1. Read the goal tracker and round contract.
        2. Keep the round focused on the mainline objective.
        3. Record blocking side issues separately from queued follow-up.
        4. Write the round summary before requesting review.

        ## Routing Rules
        - Use `coding` for implementation tasks that can be completed directly.
        - Use `analyze` for tasks that need independent investigation before implementation.
        - Do not let queued work replace the mainline objective.

        ## Review Settings
        - Model: {options.codex_model}
        - Effort: {options.codex_effort}
        - Timeout: {options.codex_timeout}s
        - Full review interval: {options.full_review_round}
        - Plan anchor: {plan_ref}
        - {push_note}

        ## Exit Preparation
        Update the goal tracker, update the round contract if scope changed, and write the summary file before stopping.
        """
    ).lstrip()
    if plan_text:
        body += "\n## Plan\n\n" + plan_text + "\n"
    return body


def setup_rlcr_loop(options: RLCRSetupOptions) -> RLCRSession:
    """Create an RLCR loop session and return its key paths."""
    project_root = options.project_root.resolve()
    if options.max_iterations < 1:
        raise RLCRError("Maximum iterations must be positive.")
    if options.codex_effort not in ALLOWED_EFFORTS:
        raise RLCRError(f"Invalid codex effort: {options.codex_effort}")
    _validate_safe(options.codex_model, "Codex model", re.compile(r"^[A-Za-z0-9._-]+$"))
    if options.full_review_round < 2:
        raise RLCRError("Full review round must be at least 2.")
    if options.codex_timeout < 1:
        raise RLCRError("Codex timeout must be positive.")
    _ensure_git_repository(project_root)
    if find_active_loop(active_loop_base(project_root)) is not None:
        raise RLCRError("An RLCR loop is already active.")
    plan_path, plan_relative = _normalize_plan_file(project_root, options.plan_file)
    if plan_path is None and not options.skip_impl:
        raise RLCRError("No plan file provided. Pass a plan file or use --skip-impl.")
    if options.track_plan_file and plan_relative is not None:
        tracked = run_git(project_root, "ls-files", "--error-unmatch", str(plan_relative), check=False).returncode == 0
        status = run_git(project_root, "status", "--porcelain", str(plan_relative)).stdout.strip()
        if not tracked:
            raise RLCRError("--track-plan-file requires the plan file to be tracked in git.")
        if status:
            raise RLCRError("--track-plan-file requires the plan file to be clean.")
    _ensure_clean_tree(project_root)
    start_branch = _current_branch(project_root)
    base_branch = determine_base_branch(project_root, options.base_branch)
    base_commit = run_git(project_root, "rev-parse", base_branch).stdout.strip()

    loop_dir = active_loop_base(project_root) / _timestamp()
    loop_dir.mkdir(parents=True, exist_ok=False)
    if plan_path is not None:
        shutil.copyfile(plan_path, loop_dir / "plan.md")
    elif options.skip_impl:
        _write(loop_dir / "plan.md", "# Review-only RLCR loop\n\nReview the current branch and resolve blocking findings.\n")

    state_file = loop_dir / "state.md"
    goal_tracker_file = loop_dir / "goal-tracker.md"
    summary_file = loop_dir / "round-0-summary.md"
    contract_file = loop_dir / "round-0-contract.md"
    prompt_file = loop_dir / "round-0-prompt.md"
    session = RLCRSession(loop_dir, state_file, goal_tracker_file, prompt_file, summary_file, contract_file)

    _write(state_file, render_state(options, plan_relative, start_branch, base_branch, base_commit))
    _write(goal_tracker_file, render_goal_tracker(options, plan_path, plan_relative))
    _write(summary_file, render_summary_template())
    _write(contract_file, render_round_contract(options, plan_relative))
    _write(prompt_file, render_prompt(options, plan_path, plan_relative, session))
    if options.skip_impl:
        _write(loop_dir / ".review-phase-started", "build_finish_round=0\n")

    pending_file = project_root / ".loop" / ".pending-session-id"
    pending_file.parent.mkdir(parents=True, exist_ok=True)
    _write(pending_file, f"{state_file}\nsetup-rlcr-loop\n")
    return session


def cancel_rlcr_loop(project_root: Path, force: bool = False) -> tuple[int, str]:
    """Cancel the active RLCR loop and return an exit code plus message."""
    loop_dir = find_active_loop(active_loop_base(project_root))
    if loop_dir is None:
        return 0, "No active RLCR loop found."
    state_order = [
        ("state.md", "NORMAL_LOOP"),
        ("methodology-analysis-state.md", "METHODOLOGY_ANALYSIS_PHASE"),
        ("finalize-state.md", "FINALIZE_PHASE"),
    ]
    active_state: Path | None = None
    phase = ""
    for name, label in state_order:
        candidate = loop_dir / name
        if candidate.is_file():
            active_state = candidate
            phase = label
            break
    if active_state is None:
        return 0, "No active RLCR loop found. The loop directory exists but no active state file is present."
    state = parse_state(active_state)
    current_round = state.get("current_round", "?") or "?"
    max_iterations = state.get("max_iterations", "?") or "?"
    if phase == "FINALIZE_PHASE" and not force:
        return (
            2,
            "FINALIZE_PHASE_DETECTED\n"
            f"current_round: {current_round}\n"
            f"max_iterations: {max_iterations}\n"
            "The loop is currently in Finalize Phase. Use --force to cancel anyway.",
        )
    (loop_dir / ".cancel-requested").touch()
    pending = project_root / ".loop" / ".pending-session-id"
    pending.unlink(missing_ok=True)
    target = loop_dir / "cancel-state.md"
    if target.exists():
        target.unlink()
    active_state.rename(target)
    if phase == "NORMAL_LOOP":
        label = "CANCELLED"
        detail = f"Cancelled RLCR loop (was at round {current_round} of {max_iterations})."
    elif phase == "METHODOLOGY_ANALYSIS_PHASE":
        label = "CANCELLED_METHODOLOGY_ANALYSIS"
        detail = f"Cancelled RLCR loop during Methodology Analysis Phase (was at round {current_round} of {max_iterations})."
    else:
        label = "CANCELLED_FINALIZE"
        detail = f"Cancelled RLCR loop during Finalize Phase (was at round {current_round} of {max_iterations})."
    return 0, f"{label}\n{detail}\nState preserved as cancel-state.md"


def run_stop_gate(project_root: Path, session_id: str = "", transcript_path: str = "", print_json: bool = False) -> tuple[int, str, str]:
    """Run the RLCR stop gate and return exit code, stdout, and stderr."""
    hook_script = project_root / "hooks" / "loop-codex-stop-hook.sh"
    if not hook_script.is_file() or not os.access(hook_script, os.X_OK):
        return 20, "", f"Error: Hook script not found or not executable: {hook_script}"
    payload = {
        "hook_event_name": "Stop",
        "stop_hook_active": False,
        "cwd": str(project_root),
        "model": os.environ.get("CODEX_MODEL", "loop-skill-gate"),
        "permission_mode": os.environ.get("CODEX_PERMISSION_MODE", "default"),
        "session_id": session_id or None,
        "transcript_path": transcript_path or None,
    }
    result = subprocess.run(
        [str(hook_script)],
        input=json.dumps(payload),
        cwd=project_root,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(project_root)},
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return 20, result.stdout, f"Error: Hook script exited with code {result.returncode}\n{result.stderr}".strip()
    output = result.stdout.strip()
    if not output:
        return 0, "ALLOW: stop gate passed.", ""
    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        return 20, "", "Error: Hook returned non-JSON output"
    decision = data.get("decision")
    if decision == "block":
        if print_json:
            return 1, json.dumps(data, indent=2, sort_keys=True), ""
        reason = data.get("reason") or data.get("systemMessage") or "Stop blocked by RLCR gate."
        return 1, f"BLOCK: {reason}", ""
    if not decision:
        if print_json:
            return 0, json.dumps(data, indent=2, sort_keys=True), ""
        message = data.get("systemMessage") or "ALLOW: stop gate passed."
        return 0, message, ""
    return 20, "", f"Error: Unexpected hook decision: {decision}"


def build_setup_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Start an RLCR loop session.")
    parser.add_argument("plan", nargs="?", help="Path to a Markdown implementation plan.")
    parser.add_argument("--plan-file", dest="plan_file")
    parser.add_argument("--track-plan-file", action="store_true")
    parser.add_argument("--max", type=lambda value: _positive_int(value, "--max"), default=DEFAULT_MAX_ITERATIONS)
    parser.add_argument("--codex-model", default=f"{DEFAULT_CODEX_MODEL}:{DEFAULT_CODEX_EFFORT}")
    parser.add_argument("--codex-timeout", type=lambda value: _positive_int(value, "--codex-timeout"), default=DEFAULT_CODEX_TIMEOUT)
    parser.add_argument("--push-every-round", action="store_true")
    parser.add_argument("--base-branch")
    parser.add_argument("--full-review-round", type=lambda value: _positive_int(value, "--full-review-round", 2), default=DEFAULT_FULL_REVIEW_ROUND)
    parser.add_argument("--skip-impl", action="store_true")
    parser.add_argument("--claude-answer-codex", action="store_true")
    parser.add_argument("--agent-teams", action="store_true")
    parser.add_argument("--yolo", action="store_true")
    parser.add_argument("--skip-quiz", action="store_true")
    parser.add_argument("--allow-empty-bitlesson-none", action="store_true")
    parser.add_argument("--require-bitlesson-entry-for-none", action="store_true")
    parser.add_argument("--privacy", action="store_true")
    parser.add_argument("--project-root", default=None, help=argparse.SUPPRESS)
    return parser


def setup_main(argv: list[str] | None = None) -> int:
    parser = build_setup_parser()
    try:
        args = parser.parse_args(argv)
        if args.plan and args.plan_file:
            raise RLCRError("Cannot specify both --plan-file and a positional plan file.")
        model_value = args.codex_model
        if ":" in model_value:
            codex_model, codex_effort = model_value.split(":", 1)
        else:
            codex_model, codex_effort = model_value, DEFAULT_CODEX_EFFORT
        project_root = resolve_project_root(Path(args.project_root) if args.project_root else None)
        plan_arg = args.plan_file or args.plan
        options = RLCRSetupOptions(
            project_root=project_root,
            plan_file=Path(plan_arg) if plan_arg else None,
            max_iterations=args.max,
            codex_model=codex_model,
            codex_effort=codex_effort,
            codex_timeout=args.codex_timeout,
            push_every_round=args.push_every_round,
            base_branch=args.base_branch,
            full_review_round=args.full_review_round,
            skip_impl=args.skip_impl,
            ask_codex_question=not (args.claude_answer_codex or args.yolo),
            agent_teams=args.agent_teams,
            track_plan_file=args.track_plan_file,
            allow_empty_bitlesson_none=args.allow_empty_bitlesson_none,
            require_bitlesson_entry_for_none=args.require_bitlesson_entry_for_none,
            methodology_analysis=not args.privacy,
        )
        session = setup_rlcr_loop(options)
    except (RLCRError, OSError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print("RLCR loop initialized.")
    print(f"Loop directory: {session.loop_dir}")
    print(f"State file: {session.state_file}")
    print(f"Prompt file: {session.prompt_file}")
    print("Next steps:")
    print(f"1. Read {session.prompt_file}")
    print(f"2. Write progress to {session.summary_file}")
    return 0


def cancel_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Cancel the active RLCR loop.")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--project-root", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        root = resolve_project_root(Path(args.project_root) if args.project_root else None)
        code, message = cancel_rlcr_loop(root, force=args.force)
    except (RLCRError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 3
    print(message)
    return code


def stop_gate_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run RLCR stop-gate checks.")
    parser.add_argument("--session-id", default=os.environ.get("CLAUDE_SESSION_ID", ""))
    parser.add_argument("--transcript-path", default=os.environ.get("CLAUDE_TRANSCRIPT_PATH", ""))
    parser.add_argument("--project-root", default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    root = resolve_project_root(Path(args.project_root) if args.project_root else None)
    code, stdout, stderr = run_stop_gate(root, args.session_id, args.transcript_path, args.json)
    if stdout:
        print(stdout)
    if stderr:
        print(stderr, file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(setup_main())
