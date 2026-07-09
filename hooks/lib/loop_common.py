#!/usr/bin/env python3
"""Shared utilities for loop hook implementations."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

try:
    from .project_root import canonicalize_path, canonicalize_path_prefix
except ImportError:
    from project_root import canonicalize_path, canonicalize_path_prefix

FIELD_NAMES = (
    "plan_tracked",
    "start_branch",
    "base_branch",
    "base_commit",
    "plan_file",
    "current_round",
    "max_iterations",
    "push_every_round",
    "codex_model",
    "codex_effort",
    "codex_timeout",
    "review_started",
    "full_review_round",
    "ask_codex_question",
    "session_id",
    "agent_teams",
    "privacy_mode",
    "mainline_stall_count",
    "last_mainline_verdict",
    "drift_status",
)
ACTIVE_STATE_NAMES = ("methodology-analysis-state.md", "finalize-state.md", "state.md")
TERMINAL_REASONS = {"complete", "cancel", "maxiter", "stop", "unexpected"}
MAINLINE_VERDICTS = {"advanced", "stalled", "regressed"}
ROUND_FILE_RE = re.compile(r"round-(\d+)-(summary|prompt|todos|contract)\.md$", re.I)


class HookInputError(ValueError):
    """Raised when a hook JSON payload is malformed."""


class StateValidationError(ValueError):
    """Raised when a state file is missing required schema fields."""


@dataclass
class HookInput:
    """Validated hook input payload."""

    tool_name: str
    tool_input: Mapping[str, Any] = field(default_factory=dict)
    raw: Mapping[str, Any] = field(default_factory=dict)


@dataclass
class LoopState:
    """Parsed loop state frontmatter with defaults applied where safe."""

    fields: dict[str, str]
    frontmatter: str
    path: Path

    def get(self, key: str, default: str = "") -> str:
        return self.fields.get(key, default)

    @property
    def current_round(self) -> int:
        return int(self.fields.get("current_round", "0"))

    @property
    def max_iterations(self) -> int:
        return int(self.fields.get("max_iterations", "10"))


def validate_hook_input(payload: str | bytes | Mapping[str, Any]) -> HookInput:
    """Validate hook JSON and extract the required tool_name field."""
    if isinstance(payload, bytes):
        if b"\x00" in payload:
            raise HookInputError("Input contains null bytes")
        try:
            data = json.loads(payload.decode("utf-8"))
        except UnicodeDecodeError as exc:
            raise HookInputError("Input contains invalid UTF-8 sequences") from exc
    elif isinstance(payload, str):
        if "\x00" in payload:
            raise HookInputError("Input contains null bytes")
        try:
            data = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise HookInputError("Invalid JSON syntax") from exc
    else:
        data = dict(payload)
    if not isinstance(data, Mapping):
        raise HookInputError("Input must be a JSON object")
    tool_name = data.get("tool_name", "")
    if not isinstance(tool_name, str) or not tool_name:
        raise HookInputError("Missing required field: tool_name")
    tool_input = data.get("tool_input", {})
    if not isinstance(tool_input, Mapping):
        tool_input = {}
    return HookInput(tool_name=tool_name, tool_input=tool_input, raw=data)


def require_tool_input_field(hook_input: HookInput | Mapping[str, Any], field_name: str) -> Any:
    """Return a required tool_input field or raise HookInputError."""
    tool_input = hook_input.tool_input if isinstance(hook_input, HookInput) else hook_input.get("tool_input", {})
    value = tool_input.get(field_name) if isinstance(tool_input, Mapping) else None
    if value in (None, ""):
        raise HookInputError(f"Missing required field: tool_input.{field_name}")
    return value


def max_json_depth(value: Any) -> int:
    """Return the maximum nesting depth of a decoded JSON value."""
    if isinstance(value, Mapping):
        return 1 + max((max_json_depth(item) for item in value.values()), default=0)
    if isinstance(value, list):
        return 1 + max((max_json_depth(item) for item in value), default=0)
    return 0


def is_deeply_nested(payload: str | Mapping[str, Any], max_depth: int = 30) -> bool:
    """Return whether a JSON payload exceeds the configured depth."""
    data = json.loads(payload) if isinstance(payload, str) else payload
    return max_json_depth(data) > max_depth


def extract_session_id(payload: str | Mapping[str, Any]) -> str:
    """Extract session_id from hook JSON input."""
    try:
        data = json.loads(payload) if isinstance(payload, str) else payload
    except json.JSONDecodeError:
        return ""
    value = data.get("session_id", "") if isinstance(data, Mapping) else ""
    return value if isinstance(value, str) else ""


def resolve_active_state_file(loop_dir: str | Path) -> Path | None:
    """Return the active state file in priority order."""
    root = Path(loop_dir)
    for name in ACTIVE_STATE_NAMES:
        candidate = root / name
        if candidate.is_file():
            return candidate
    return None


def resolve_any_state_file(loop_dir: str | Path) -> Path | None:
    """Return an active state file, or the first terminal state file."""
    active = resolve_active_state_file(loop_dir)
    if active:
        return active
    states = sorted(Path(loop_dir).glob("*-state.md"))
    return states[0] if states else None


def _frontmatter_lines(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    result: list[str] = []
    for line in lines[1:]:
        if line.strip() == "---":
            return result
        result.append(line)
    return []


def _parse_frontmatter(path: Path) -> tuple[str, dict[str, str]]:
    lines = _frontmatter_lines(path)
    fields: dict[str, str] = {}
    for line in lines:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if key in FIELD_NAMES:
            fields[key] = value.strip().strip('"')
    return "\n".join(lines), fields


def parse_state_file(path: str | Path, strict: bool = False) -> LoopState:
    """Parse a state file with compatibility defaults."""
    state_path = Path(path)
    if not state_path.is_file():
        raise FileNotFoundError(state_path)
    frontmatter, fields = _parse_frontmatter(state_path)
    if strict:
        text = state_path.read_text(encoding="utf-8")
        if text.splitlines().count("---") < 2:
            raise StateValidationError("Missing YAML frontmatter separators")
        for key in ("current_round", "max_iterations", "review_started", "base_branch"):
            if not fields.get(key):
                raise StateValidationError(f"Missing required field: {key}")
        if not re.fullmatch(r"-?\d+", fields["current_round"]):
            raise StateValidationError(f"Non-numeric current_round value: {fields['current_round']}")
        if not re.fullmatch(r"-?\d+", fields["max_iterations"]):
            raise StateValidationError(f"Non-numeric max_iterations value: {fields['max_iterations']}")
        if fields["review_started"] not in {"true", "false"}:
            raise StateValidationError("review_started must be true or false")
    defaults = {
        "current_round": "0",
        "max_iterations": "10",
        "push_every_round": "false",
        "full_review_round": "5",
        "ask_codex_question": "true",
        "agent_teams": "false",
        "privacy_mode": "true",
        "mainline_stall_count": "0",
        "last_mainline_verdict": "unknown",
        "drift_status": "normal",
    }
    for key, value in defaults.items():
        fields.setdefault(key, value)
    return LoopState(fields=fields, frontmatter=frontmatter, path=state_path)


def get_current_round(state_file: str | Path) -> int:
    """Return the current round from a state file, defaulting to zero."""
    try:
        return parse_state_file(state_file).current_round
    except (FileNotFoundError, ValueError):
        return 0


def find_active_loop(
    loop_base_dir: str | Path,
    filter_session_id: str = "",
    allow_bg_marker_fallback: bool = False,
) -> Path | None:
    """Find the newest active loop, preserving stale-loop protections."""
    root = Path(loop_base_dir)
    if not root.is_dir():
        return None
    directories = sorted((path for path in root.iterdir() if path.is_dir()), key=lambda path: path.name, reverse=True)
    if not filter_session_id:
        newest = directories[0] if directories else None
        return newest if newest and resolve_active_state_file(newest) else None
    marker_candidate: Path | None = None
    for directory in directories:
        state = resolve_any_state_file(directory)
        if not state:
            continue
        stored_session_id = parse_state_file(state).get("session_id", "").replace(" ", "")
        if not stored_session_id or stored_session_id == filter_session_id:
            return directory if resolve_active_state_file(directory) else None
        if allow_bg_marker_fallback and marker_candidate is None and (directory / "bg-pending.marker").is_file():
            if resolve_active_state_file(directory):
                marker_candidate = directory
    return marker_candidate if allow_bg_marker_fallback else None


def normalize_mainline_progress_verdict(value: str) -> str:
    """Normalize review progress verdicts to a safe enum."""
    lowered = re.sub(r"\s+", "", value.lower())
    return lowered if lowered in MAINLINE_VERDICTS else "unknown"


def normalize_drift_status(value: str) -> str:
    """Normalize drift status to a safe enum."""
    return "replan_required" if re.sub(r"\s+", "", value.lower()) == "replan_required" else "normal"


def extract_mainline_progress_verdict(review_content: str) -> str:
    """Extract the final unambiguous Mainline Progress Verdict from review content."""
    lines = [line for line in review_content.splitlines() if re.search(r"Mainline Progress Verdict:\s*(ADVANCED|STALLED|REGRESSED)([^A-Za-z]|$)", line, re.I)]
    if not lines:
        return "unknown"
    matches = re.findall(r"ADVANCED|STALLED|REGRESSED", lines[-1], flags=re.I)
    if len(matches) != 1:
        return "unknown"
    return normalize_mainline_progress_verdict(matches[0])


def upsert_state_fields(path: str | Path, updates: Mapping[str, str]) -> None:
    """Insert or replace simple YAML frontmatter fields."""
    state_path = Path(path)
    lines = state_path.read_text(encoding="utf-8").splitlines()
    if lines.count("---") < 2:
        raise StateValidationError("Missing YAML frontmatter separators")
    result: list[str] = []
    seen: set[str] = set()
    separator_count = 0
    for line in lines:
        if line == "---":
            separator_count += 1
            if separator_count == 2:
                for key, value in updates.items():
                    if key not in seen:
                        result.append(f"{key}: {value}")
                        seen.add(key)
            result.append(line)
            continue
        replaced = False
        if separator_count == 1 and ":" in line:
            key = line.split(":", 1)[0].strip()
            if key in updates:
                result.append(f"{key}: {updates[key]}")
                seen.add(key)
                replaced = True
        if not replaced:
            result.append(line)
    state_path.write_text("\n".join(result) + "\n", encoding="utf-8")


def is_round_file_type(path_lower: str, file_type: str) -> bool:
    """Return whether a path targets a round file of the requested type."""
    return bool(re.search(rf"round-[0-9]+-{re.escape(file_type)}\.md$", path_lower))


def extract_round_number(filename: str) -> str:
    """Extract the round number from a round file path."""
    match = ROUND_FILE_RE.search(filename)
    return match.group(1) if match else ""


def is_goal_tracker_path(path_lower: str) -> bool:
    return bool(re.search(r"goal-tracker\.md$", path_lower))


def is_state_file_path(path_lower: str) -> bool:
    return bool(re.search(r"state\.md$", path_lower))


def is_finalize_state_file_path(path_lower: str) -> bool:
    return bool(re.search(r"finalize-state\.md$", path_lower))


def is_methodology_analysis_state_file_path(path_lower: str) -> bool:
    return bool(re.search(r"methodology-analysis-state\.md$", path_lower))


def is_finalize_summary_path(path_lower: str) -> bool:
    return bool(re.search(r"finalize-summary\.md$", path_lower))


def extract_goal_tracker_immutable_from_text(content: str) -> str:
    """Extract the immutable section from goal tracker Markdown."""
    capture = False
    lines: list[str] = []
    for line in content.splitlines():
        if line.strip() == "## IMMUTABLE SECTION":
            capture = True
        if capture and (line.strip() == "## MUTABLE SECTION" or line.strip() == "---"):
            break
        if capture:
            lines.append(line)
    return "\n".join(lines)


def extract_goal_tracker_immutable_from_file(path: str | Path) -> str:
    file_path = Path(path)
    if not file_path.is_file():
        raise FileNotFoundError(file_path)
    return extract_goal_tracker_immutable_from_text(file_path.read_text(encoding="utf-8"))


def goal_tracker_mutable_update_allowed(path: str | Path, new_content: str) -> bool:
    """Return whether an update preserves the immutable section."""
    current = extract_goal_tracker_immutable_from_file(path)
    if not current:
        return True
    return current == extract_goal_tracker_immutable_from_text(new_content)


def preview_edit_result(path: str | Path, old_string: str, new_string: str, replace_all: bool = False) -> str:
    """Render the post-edit contents for a literal edit operation."""
    content = Path(path).read_text(encoding="utf-8")
    return content.replace(old_string, new_string) if replace_all else content.replace(old_string, new_string, 1)


def is_cancel_authorized(active_loop_dir: str | Path, command: str) -> bool:
    """Validate a narrow state-to-cancel mv command authorized by a signal file."""
    loop_dir = Path(canonicalize_path(active_loop_dir))
    if not (loop_dir / ".cancel-requested").is_file():
        return False
    command_lower = command.lower()
    if any(token in command_lower for token in ("$(", "`", "\n", ";", "&&", "||", "|")):
        return False
    if re.search(r"\s{2,}$", command_lower):
        return False
    normalized = command_lower.replace("${loop_dir}/", str(loop_dir).lower() + "/").replace("$loop_dir/", str(loop_dir).lower() + "/")
    if "$" in normalized:
        return False
    try:
        parts = shlex.split(normalized)
    except ValueError:
        return False
    if len(parts) != 3 or parts[0] != "mv":
        return False
    src, dest = parts[1:]
    allowed_sources = {
        str(loop_dir / "state.md").lower(),
        str(loop_dir / "finalize-state.md").lower(),
        str(loop_dir / "methodology-analysis-state.md").lower(),
    }
    src_canonical = canonicalize_path_prefix(src).lower()
    dest_canonical = canonicalize_path_prefix(dest).lower()
    if src_canonical not in allowed_sources or dest_canonical != str(loop_dir / "cancel-state.md").lower():
        return False
    original = loop_dir / Path(src_canonical).name
    return not original.is_symlink()


def is_in_loop_dir(path: str) -> bool:
    return ".loop/rlcr/" in path


def git_adds_loop(command_lower: str, project_root: str | Path = ".") -> bool:
    """Return whether a git add command would stage local loop state."""
    for segment in re.split(r"&&|\|\||\||;", command_lower):
        if not re.search(r"(^|\s)git\s+([^\s]+\s+)*add(\s|$)", segment):
            continue
        add_args = re.sub(r".*\sadd\s*", "", segment)
        normalized = add_args.replace("'", "").replace('"', "")
        if re.search(r"(^|\s|/)\.loop($|/|\s)", normalized):
            return True
        has_force = bool(re.search(r"(^|\s)--force(\s|$)|(^|\s)-[a-z]*f[a-z]*(\s|$)", add_args))
        has_all = bool(re.search(r"(^|\s)--all(\s|$)|(^|\s)-[a-z]*a[a-z]*(\s|$)", add_args))
        has_broad_scope = bool(re.search(r"(^|\s)(\.|\*)(\s|$)", add_args))
        if has_force and (has_all or has_broad_scope):
            return True
        root = Path(project_root)
        if not (root / ".loop").is_dir():
            continue
        if has_all:
            return True
        if has_broad_scope:
            ignored = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", ".loop"]).returncode == 0
            if not ignored:
                return True
    return False


def git_has_tracked_loop_state(project_root: str | Path = ".") -> bool:
    """Return whether .loop state is tracked or staged."""
    root = Path(project_root)
    result = subprocess.run(["git", "-C", str(root), "ls-files", "--", ".loop"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.returncode == 0 and bool(result.stdout.strip())


def command_modifies_file(command_lower: str, file_pattern: str) -> bool:
    """Return whether a shell command attempts to modify a file pattern."""
    patterns = [
        rf">\s*[^\s]*{file_pattern}",
        rf">>\s*[^\s]*{file_pattern}",
        rf"tee\s+(-a\s+)?[^\s]*{file_pattern}",
        rf"sed\s+-i[^|]*{file_pattern}",
        rf"awk\s+-i\s+inplace[^|]*{file_pattern}",
        rf"perl\s+-[^\s]*i[^|]*{file_pattern}",
        rf"(mv|cp)\s+[^\s]+\s+[^\s]*{file_pattern}",
        rf"rm\s+(-[rfv]+\s+)?[^\s]*{file_pattern}",
        rf"dd\s+.*of=[^\s]*{file_pattern}",
        rf"truncate\s+[^|]*{file_pattern}",
        rf"printf\s+.*>\s*[^\s]*{file_pattern}",
        rf"exec\s+[0-9]*>\s*[^\s]*{file_pattern}",
    ]
    return any(re.search(pattern, command_lower) for pattern in patterns)


def end_loop(loop_dir: str | Path, state_file: str | Path, reason: str) -> Path:
    """End a loop by renaming the state file to a terminal state."""
    if reason not in TERMINAL_REASONS:
        raise ValueError(f"Invalid end_loop reason: {reason}")
    source = Path(state_file)
    if not source.is_file():
        raise FileNotFoundError(source)
    target = Path(loop_dir) / f"{reason}-state.md"
    source.rename(target)
    return target


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Shared hook utility commands.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    current_round = subparsers.add_parser("current-round")
    current_round.add_argument("state_file")
    verdict = subparsers.add_parser("verdict")
    verdict.add_argument("review_file")
    active = subparsers.add_parser("active-state")
    active.add_argument("loop_dir")
    git_adds = subparsers.add_parser("git-adds-loop")
    git_adds.add_argument("command_lower")
    git_adds.add_argument("project_root", nargs="?", default=".")
    modifies = subparsers.add_parser("command-modifies-file")
    modifies.add_argument("command_lower")
    modifies.add_argument("file_pattern")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "current-round":
        print(get_current_round(args.state_file))
        return 0
    if args.command == "verdict":
        print(extract_mainline_progress_verdict(Path(args.review_file).read_text(encoding="utf-8")))
        return 0
    if args.command == "active-state":
        path = resolve_active_state_file(args.loop_dir)
        if path:
            print(path)
            return 0
        return 1
    if args.command == "git-adds-loop":
        return 0 if git_adds_loop(args.command_lower, args.project_root) else 1
    if args.command == "command-modifies-file":
        return 0 if command_modifies_file(args.command_lower, args.file_pattern) else 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
