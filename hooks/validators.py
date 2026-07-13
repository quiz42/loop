#!/usr/bin/env python3
"""Hook validators for loop safety rules."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

try:
    from hooks.lib import loop_common, project_root
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from hooks.lib import loop_common, project_root


@dataclass
class ValidationResult:
    """Result returned by a hook validator."""

    allowed: bool = True
    message: str = ""
    exit_code: int = 0

    @classmethod
    def allow(cls) -> "ValidationResult":
        return cls(True, "", 0)

    @classmethod
    def block(cls, message: str, exit_code: int = 2) -> "ValidationResult":
        return cls(False, message, exit_code)

    @classmethod
    def error(cls, message: str, exit_code: int = 1) -> "ValidationResult":
        return cls(False, message, exit_code)


TOOL_FOR_VALIDATOR = {
    "write": "Write",
    "edit": "Edit",
    "read": "Read",
    "bash": "Bash",
}

METHODOLOGY_ALLOWED_WRITE_FILES = {"methodology-analysis-report.md", "methodology-analysis-done.md"}
METHODOLOGY_ALLOWED_READ_FILES = METHODOLOGY_ALLOWED_WRITE_FILES | {"methodology-analysis-state.md"}
STATE_FILE_NAMES = {"state.md", "finalize-state.md", "methodology-analysis-state.md"}
READ_ONLY_BASH_PREFIXES = (
    "cat",
    "cd",
    "echo",
    "find",
    "git diff",
    "git log",
    "git show",
    "git status",
    "grep",
    "head",
    "ls",
    "pwd",
    "rg",
    "sed -n",
    "tail",
    "test",
    "wc",
)


def load_hook_input(stdin: str | None = None) -> Mapping[str, Any]:
    """Load hook input JSON from a string or stdin."""
    text = sys.stdin.read() if stdin is None else stdin
    if not text.strip():
        return {}
    data = json.loads(text)
    if not isinstance(data, Mapping):
        raise loop_common.HookInputError("Hook input must be a JSON object")
    return data


def _validate_payload(payload: Mapping[str, Any]) -> loop_common.HookInput:
    hook_input = loop_common.validate_hook_input(payload)
    if loop_common.is_deeply_nested(payload, 30):
        raise loop_common.HookInputError("Hook input is too deeply nested")
    return hook_input


def _project_root(env: Mapping[str, str] | None = None) -> Path | None:
    try:
        return project_root.resolve_project_root(env=env)
    except Exception:
        return None


def _active_loop(payload: Mapping[str, Any], env: Mapping[str, str] | None = None) -> Path | None:
    root = _project_root(env)
    if not root:
        return None
    session_id = loop_common.extract_session_id(payload)
    return loop_common.find_active_loop(root / ".loop" / "rlcr", session_id)


def _active_state(loop_dir: Path | None) -> tuple[Path | None, loop_common.LoopState | None]:
    if not loop_dir:
        return None, None
    state_file = loop_common.resolve_active_state_file(loop_dir)
    if not state_file:
        return None, None
    try:
        return state_file, loop_common.parse_state_file(state_file, strict=True)
    except Exception:
        return state_file, None


def _path_is_inside(path: Path, directory: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(directory.resolve(strict=False))
        return True
    except ValueError:
        return False


def _resolve_input_path(path: str, root: Path | None) -> Path:
    value = Path(path).expanduser()
    if value.is_absolute() or root is None:
        return value
    return root / value


def _is_loop_path(path: str | Path) -> bool:
    return ".loop/rlcr/" in str(path).replace(os.sep, "/")


def _round_kind(path: str) -> str:
    match = re.search(r"round-(\d+)-(summary|prompt|todos|contract)\.md$", path, re.I)
    return match.group(2).lower() if match else ""


def _round_number(path: str) -> int | None:
    match = re.search(r"round-(\d+)-(summary|prompt|todos|contract)\.md$", path, re.I)
    return int(match.group(1)) if match else None


def _block_message(title: str, detail: str) -> str:
    return f"# {title}\n\n{detail}"


def _current_git_branch(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _validate_active_plan_state(root: Path, payload: Mapping[str, Any]) -> ValidationResult | None:
    loop_dir = _active_loop(payload)
    if not loop_dir:
        return None
    state_file = loop_common.resolve_active_state_file(loop_dir)
    if not state_file:
        return None
    try:
        state = loop_common.parse_state_file(state_file, strict=True)
    except Exception as exc:
        return ValidationResult.block(
            _block_message("Plan State Blocked", f"The active loop state is malformed: {exc}")
        )

    start_branch = state.get("start_branch", "")
    if start_branch:
        current_branch = _current_git_branch(root)
        if current_branch and current_branch != start_branch:
            return ValidationResult.block(
                _block_message(
                    "Plan Branch Blocked",
                    f"The active loop started on branch '{start_branch}', but the current branch is '{current_branch}'.",
                )
            )

    plan_file = state.get("plan_file", "")
    if not plan_file:
        return None
    project_plan = _resolve_input_path(plan_file, root)
    if not _path_is_inside(project_plan, root) or not project_plan.is_file():
        return ValidationResult.block(
            _block_message("Plan File Blocked", "The tracked plan file must exist inside the project workspace.")
        )
    backup_plan = loop_dir / "plan.md"
    if not backup_plan.is_file():
        return ValidationResult.block(
            _block_message("Plan Backup Blocked", "The active loop plan backup is missing.")
        )
    if project_plan.read_text(encoding="utf-8") != backup_plan.read_text(encoding="utf-8"):
        return ValidationResult.block(
            _block_message("Plan File Modified", f"The tracked plan file '{plan_file}' has been modified since the loop started.")
        )
    return None


def _stop_block(result: ValidationResult | None) -> ValidationResult | None:
    if result is None or result.allowed:
        return result
    return ValidationResult.block(result.message, 0)


def _methodology_file_result(action: str, path: Path, loop_dir: Path, allowed: set[str]) -> ValidationResult | None:
    if not (loop_dir / "methodology-analysis-state.md").is_file():
        return None
    if _path_is_inside(path, loop_dir) and path.name in allowed:
        return ValidationResult.allow()
    if action == "Read" and not _path_is_inside(path, loop_dir):
        root = _project_root()
        if root and not _path_is_inside(path, root):
            return ValidationResult.allow()
    allowed_text = ", ".join(sorted(allowed))
    return ValidationResult.block(
        _block_message(
            f"{action} Blocked During Methodology Analysis",
            f"Only methodology artifacts can be used during this phase. Allowed: {allowed_text}",
        )
    )


def _validate_file_tool(action: str, payload: Mapping[str, Any]) -> ValidationResult:
    try:
        hook_input = _validate_payload(payload)
    except Exception as exc:
        return ValidationResult.error(str(exc))
    if hook_input.tool_name != action:
        return ValidationResult.allow()
    try:
        file_path = str(loop_common.require_tool_input_field(hook_input, "file_path"))
    except loop_common.HookInputError as exc:
        return ValidationResult.error(str(exc))

    lower = file_path.lower()
    root = _project_root()
    resolved_path = _resolve_input_path(file_path, root)
    loop_dir = _active_loop(payload)
    state_file, state = _active_state(loop_dir)

    if loop_dir:
        methodology = _methodology_file_result(
            action,
            resolved_path,
            loop_dir,
            METHODOLOGY_ALLOWED_READ_FILES if action == "Read" else METHODOLOGY_ALLOWED_WRITE_FILES,
        )
        if methodology is not None and not methodology.allowed:
            return methodology
        if methodology is not None and methodology.allowed:
            return methodology

    round_kind = _round_kind(lower)
    if round_kind == "todos":
        return ValidationResult.block(
            _block_message(f"{action} Blocked", "Round todo files are managed by the task system and must not be edited directly.")
        )
    if round_kind == "prompt" and action in {"Write", "Edit"}:
        return ValidationResult.block(_block_message("Prompt Write Blocked", "Round prompt files are generated artifacts and are read-only."))

    if not loop_dir or not state_file or not state:
        return ValidationResult.allow()

    if resolved_path.name in STATE_FILE_NAMES:
        return ValidationResult.block(_block_message("State File Blocked", "Loop state files are controlled by the loop runtime."))

    if state_file.name == "finalize-state.md" and round_kind == "contract":
        return ValidationResult.block(_block_message("Finalize Contract Blocked", "Round contract files are not used during finalize."))

    if loop_common.is_goal_tracker_path(lower):
        active_goal = loop_dir / "goal-tracker.md"
        if resolved_path.resolve(strict=False) != active_goal.resolve(strict=False):
            return ValidationResult.block(
                _block_message("Goal Tracker Blocked", "Use the goal tracker for the active loop only.")
            )
        if action in {"Write", "Edit"} and active_goal.is_file():
            if action == "Write":
                new_content = str(hook_input.tool_input.get("content", ""))
            else:
                old_string = str(hook_input.tool_input.get("old_string", ""))
                new_string = str(hook_input.tool_input.get("new_string", ""))
                replace_all = bool(hook_input.tool_input.get("replace_all", False))
                try:
                    new_content = loop_common.preview_edit_result(active_goal, old_string, new_string, replace_all)
                except Exception:
                    return ValidationResult.block(
                        _block_message("Goal Tracker Blocked", "The goal tracker edit could not be previewed safely.")
                    )
            if not loop_common.goal_tracker_mutable_update_allowed(active_goal, new_content):
                return ValidationResult.block(
                    _block_message("Goal Tracker Blocked", "The immutable goal tracker section must be preserved.")
                )
        return ValidationResult.allow()

    if round_kind in {"summary", "contract"}:
        current_round = state.current_round
        requested_round = _round_number(lower)
        if requested_round != current_round:
            return ValidationResult.block(
                _block_message(
                    "Wrong Round File Blocked",
                    f"Use round-{current_round}-{round_kind}.md for the active loop round.",
                )
            )
        if action == "Write" and not _path_is_inside(resolved_path, loop_dir):
            return ValidationResult.block(
                _block_message("Round File Blocked", "Round files must be written inside the active loop directory.")
            )

    if action == "Read" and loop_common.is_goal_tracker_path(lower) and not _path_is_inside(resolved_path, loop_dir):
        return ValidationResult.block(_block_message("Read Blocked", "Old loop goal trackers cannot be read."))

    return ValidationResult.allow()


def validate_write(payload: Mapping[str, Any]) -> ValidationResult:
    return _validate_file_tool("Write", payload)


def validate_edit(payload: Mapping[str, Any]) -> ValidationResult:
    return _validate_file_tool("Edit", payload)


def validate_read(payload: Mapping[str, Any]) -> ValidationResult:
    return _validate_file_tool("Read", payload)


def _looks_like_hook_script_launch(command_lower: str) -> bool:
    return bool(re.search(r"(^|[;&|]\s*)(env\s+[^;&|]+\s+|command\s+|timeout\s+\S+\s+|nice\s+|nohup\s+)*(bash|sh|zsh|source|\.|\./|/)?[^;&|]*(loop-codex-stop-hook\.sh|rlcr-stop-gate\.sh)", command_lower))


def _methodology_bash_result(command_lower: str) -> ValidationResult | None:
    if re.match(r"^\s*(\"?([^\s\"]+/)?cancel-rlcr-loop\.sh\"?)(\s|$)", command_lower) and not re.search(r"[;|&`<>]|\$\(|\n", command_lower):
        return ValidationResult.allow()
    checks = [
        (r"(^|[\s;|&])git\s+(commit|add|reset|checkout|merge|rebase|cherry-pick|am|apply|stash|push|restore|clean|rm|mv|switch|pull|clone|submodule|worktree)", "Git write commands are not allowed during the methodology analysis phase."),
        (r"(^|[\s;|&])(tee|install|touch|mv|cp|rm|dd|truncate|chmod|chown|mkdir|rmdir|ln|mktemp|patch)\s", "File modification commands are not allowed during the methodology analysis phase."),
        (r"sed\s+-i|awk\s+-i\s+inplace|perl\s+-[^\s]*i", "In-place file editing is not allowed during the methodology analysis phase."),
        (r"(^|[\s;|&])(python[23]?|ruby|node|perl|php)\s", "Running interpreters is not allowed during the methodology analysis phase."),
        (r"(^|[\s;|&])(/usr/bin/env\s+)?(bash|sh|zsh|/bin/bash|/bin/sh|/bin/zsh)\s", "Running shell scripts is not allowed during the methodology analysis phase."),
        (r"(^|[\s;|&])(make|cmake|ninja|gradle|mvn|ant|cargo|go\s+run|go\s+generate|npm\s+run|yarn\s+run|npx|pnpm)\s", "Build tools are not allowed during the methodology analysis phase."),
        (r"(^|[\s;|&])(source|\.)\s+[^\s]", "Sourcing scripts is not allowed during the methodology analysis phase."),
        (r"(^|[\s;|&])\.{0,2}/[^\s>|&;]*\.(sh|bash|py|rb|pl|js)", "Direct script execution is not allowed during the methodology analysis phase."),
    ]
    for pattern, message in checks:
        if re.search(pattern, command_lower):
            return ValidationResult.block(_block_message("Bash Blocked During Methodology Analysis", message))
    stripped = re.sub(r"[0-9]*>>?\s*/dev/[^\s]*", "", command_lower)
    stripped = re.sub(r"[0-9]*>&[0-9]*", "", stripped)
    if ">" in stripped:
        return ValidationResult.block(
            _block_message("Bash Blocked During Methodology Analysis", "File redirection is not allowed during the methodology analysis phase.")
        )
    return None


def validate_bash(payload: Mapping[str, Any]) -> ValidationResult:
    try:
        hook_input = _validate_payload(payload)
    except Exception as exc:
        return ValidationResult.error(str(exc))
    if hook_input.tool_name != "Bash":
        return ValidationResult.allow()
    try:
        command = str(loop_common.require_tool_input_field(hook_input, "command"))
    except loop_common.HookInputError as exc:
        return ValidationResult.error(str(exc))

    command_lower = command.lower()
    loop_dir = _active_loop(payload)
    state_file, state = _active_state(loop_dir)

    if loop_dir and (loop_dir / "methodology-analysis-state.md").is_file():
        methodology = _methodology_bash_result(command_lower)
        if methodology is not None:
            return methodology

    if not loop_dir or not state_file or not state:
        return ValidationResult.allow()

    if _looks_like_hook_script_launch(command_lower):
        return ValidationResult.block(_block_message("Hook Execution Blocked", "Loop hook and stop gate scripts cannot be invoked manually."))

    root = _project_root()
    if root and loop_common.git_adds_loop(command_lower, root):
        return ValidationResult.block(_block_message("Git Add Blocked", "Do not stage local .loop runtime state."))

    blocked_files = [
        (r"methodology-analysis-state\.md", "State File Blocked"),
        (r"finalize-state\.md", "State File Blocked"),
        (r"state\.md", "State File Blocked"),
        (r"\.loop/rlcr(/[^/]+)?/plan\.md", "Plan Backup Blocked"),
        (r"goal-tracker\.md", "Goal Tracker Blocked"),
        (r"round-[0-9]+-prompt\.md", "Prompt Write Blocked"),
        (r"round-[0-9]+-summary\.md", "Summary Bash Write Blocked"),
        (r"round-[0-9]+-contract\.md", "Round Contract Bash Write Blocked"),
        (r"round-[0-9]+-todos\.md", "Todos Bash Write Blocked"),
    ]
    for pattern, title in blocked_files:
        if loop_common.command_modifies_file(command_lower, pattern):
            return ValidationResult.block(_block_message(title, "Use the dedicated tool flow for protected loop files."))

    return ValidationResult.allow()


def validate_plan_prompt(payload: Mapping[str, Any]) -> ValidationResult:
    root = _project_root()
    if not root:
        return ValidationResult.allow()
    active_state_result = _validate_active_plan_state(root, payload)
    if active_state_result is not None:
        return active_state_result
    prompt = str(payload.get("prompt", "") or payload.get("user_prompt", ""))
    if not prompt:
        return ValidationResult.allow()
    plan_patterns = [r"(^|\s)(/tmp/[^\s]+\.md)", r"(^|\s)([^\s]+plan[^\s]*\.md)"]
    candidates: list[Path] = []
    for pattern in plan_patterns:
        for match in re.finditer(pattern, prompt, re.I):
            value = match.group(2)
            candidates.append(_resolve_input_path(value, root))
    if not candidates:
        return ValidationResult.allow()
    for candidate in candidates:
        try:
            candidate.resolve(strict=False).relative_to(root.resolve(strict=False))
            if candidate.is_file():
                return ValidationResult.allow()
        except ValueError:
            continue
    return ValidationResult.block(
        _block_message("Plan File Blocked", "Referenced plan files must exist inside the project workspace.")
    )


def post_bash_hook(payload: Mapping[str, Any]) -> ValidationResult:
    command = str(payload.get("tool_input", {}).get("command", "") if isinstance(payload.get("tool_input", {}), Mapping) else "")
    if "setup-rlcr-loop.sh" not in command:
        return ValidationResult.allow()
    root = _project_root()
    if not root:
        return ValidationResult.allow()
    marker = root / ".loop" / "last-setup-command.txt"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(command + "\n", encoding="utf-8")
    return ValidationResult.allow()


def _git_is_clean(root: Path) -> bool:
    result = subprocess.run(["git", "-C", str(root), "status", "--porcelain"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.returncode != 0 or not result.stdout.strip()


def stop_hook(payload: Mapping[str, Any]) -> ValidationResult:
    root = _project_root()
    if not root:
        return ValidationResult.allow()
    loop_dir = _active_loop(payload)
    state_file, state = _active_state(loop_dir)
    if not loop_dir or not state_file or not state:
        return ValidationResult.allow()

    plan_state_result = _stop_block(_validate_active_plan_state(root, payload))
    if plan_state_result is not None:
        return plan_state_result

    if not _git_is_clean(root):
        return ValidationResult.block(_block_message("Loop Blocked", "Uncommitted changes detected; commit or revert them before stopping."), 0)

    current_round = state.current_round
    summary = loop_dir / ("finalize-summary.md" if state_file.name == "finalize-state.md" else f"round-{current_round}-summary.md")
    if not summary.is_file() or not summary.read_text(encoding="utf-8").strip():
        return ValidationResult.block(_block_message("Loop Blocked", f"Missing required summary file: {summary.name}"), 0)

    goal_tracker = loop_dir / "goal-tracker.md"
    if not goal_tracker.is_file() or "TODO" in goal_tracker.read_text(encoding="utf-8").upper():
        return ValidationResult.block(_block_message("Loop Blocked", "The active goal tracker must be initialized before stopping."), 0)

    if current_round >= state.max_iterations:
        loop_common.end_loop(loop_dir, state_file, "maxiter")
        return ValidationResult.allow()
    return ValidationResult.block(
        _block_message("Loop Blocked", "The loop remains active and requires review before exit."),
        0,
    )


def run_validator(name: str, stdin: str | None = None) -> ValidationResult:
    try:
        payload = load_hook_input(stdin)
    except json.JSONDecodeError as exc:
        return ValidationResult.error(f"Invalid JSON syntax: {exc}")
    validators = {
        "write": validate_write,
        "edit": validate_edit,
        "read": validate_read,
        "bash": validate_bash,
        "plan": validate_plan_prompt,
        "post-bash": post_bash_hook,
        "stop": stop_hook,
    }
    try:
        return validators[name](payload)
    except KeyError:
        return ValidationResult.error(f"Unknown validator: {name}")


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("Usage: validators.py <write|edit|read|bash|plan|post-bash|stop>", file=sys.stderr)
        return 1
    result = run_validator(args[0])
    if result.message:
        print(result.message, file=sys.stderr if result.exit_code else sys.stdout)
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
