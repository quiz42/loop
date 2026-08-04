"""Read-only Proof of Loop compiler and validator primitives.

The public CLI is deliberately kept thin: this module owns all of the
compatibility logic for Loop Run files, evidence identities, bundle writing,
and offline validation.  It uses only the Python standard library so a fresh
checkout can export a bundle without installing dependencies.
"""

from __future__ import annotations

import datetime as _datetime
import fnmatch
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple, Union

from .contract import (
    canonical_json_bytes,
    compute_proof_id,
    compute_run_id,
    load_schema,
    validate_instance,
)


TERMINAL_STATES = frozenset(("complete", "stop", "cancel", "maxiter", "unexpected"))
EXIT_VALID = 0
EXIT_INCOMPLETE = 2
EXIT_INVALID = 3


class ProofError(RuntimeError):
    """Base class for deterministic Proof compiler errors."""


class RunUnreadableError(ProofError):
    """The source Run cannot be read or does not have a usable state file."""


class ActiveRunError(ProofError):
    """The source Run is still active and therefore unsafe to snapshot."""


class SecretScanError(ProofError):
    """A profile's fail-on scanner found a possible secret."""

    def __init__(self, target: str, match_type: str) -> None:
        self.target = target
        self.match_type = match_type
        super().__init__(f"secret scan failed for {target}: {match_type}")


class BundleWriteError(ProofError):
    """A bundle could not be written safely."""


def _parse_scalar(raw: str) -> Any:
    """Parse the small scalar subset emitted by Loop state frontmatter."""
    value = raw.strip()
    if not value:
        return ""
    if value in ("null", "Null", "NULL", "~"):
        return None
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    if (value.startswith("\"") and value.endswith("\"")) or (
        value.startswith("'") and value.endswith("'")
    ):
        # State values are not arbitrary YAML; preserving the inner text is
        # preferable to pulling in a YAML dependency for this parser.
        return value[1:-1]
    if re.fullmatch(r"-?[0-9]+", value):
        try:
            return int(value)
        except ValueError:
            pass
    return value


def read_frontmatter(path: Path) -> Dict[str, Any]:
    """Read Loop's ``---`` key/value frontmatter without modifying the file."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise RunUnreadableError(f"cannot read state file {path}: {error}") from error

    lines = text.splitlines()
    try:
        start = next(index for index, line in enumerate(lines) if line.strip() == "---")
        end = next(
            index for index in range(start + 1, len(lines)) if lines[index].strip() == "---"
        )
    except StopIteration as error:
        raise RunUnreadableError(f"state file {path} has no frontmatter") from error

    values: Dict[str, Any] = {}
    for line in lines[start + 1 : end]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in line:
            continue
        key, raw = line.split(":", 1)
        key = key.strip()
        if not key:
            continue
        values[key] = _parse_scalar(raw)
    return values


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None


def _first_heading_section(text: str, heading: str) -> Optional[str]:
    """Return content until the next heading at the same or higher level."""
    lines = text.splitlines()
    wanted = heading.strip().lower()
    start: Optional[int] = None
    level = 0
    for index, line in enumerate(lines):
        match = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if not match:
            continue
        if match.group(2).strip().lower() == wanted:
            start = index + 1
            level = len(match.group(1))
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start, len(lines)):
        match = re.match(r"^(#{1,6})\s+", lines[index])
        if match and len(match.group(1)) <= level:
            end = index
            break
    return "\n".join(lines[start:end]).strip()


_EXPLICIT_AC_LABEL = re.compile(r"^AC-?([0-9]+)\s*:\s*(.*)$", re.IGNORECASE)
_AC_REFERENCE = re.compile(
    r"\bAC-?([0-9]+)(?=(?:\s|[,;|)]|$|:\s|:$))", re.IGNORECASE
)
_AC_REFERENCE_ATTEMPT = re.compile(
    r"(?<![A-Za-z0-9_])AC(?:[-_ ]?[^\s,;|)]*|[-_])",
    re.IGNORECASE,
)


def _ac_id(number: str) -> str:
    """Normalize an AC number into the stable identifier used in a Bundle."""
    return f"ac-{number.lstrip('0') or '0'}"


def _looks_like_malformed_ac_label(raw: str) -> bool:
    """Recognize an attempted AC label that is not in the v0 label form."""
    return bool(
        re.match(r"^AC(?:[0-9_-].*| [^:]*|)?\s*:", raw, flags=re.IGNORECASE)
        or re.match(r"^AC(?:[0-9]|[-_][0-9])(?:\s|$)", raw, flags=re.IGNORECASE)
    )


def _parse_criteria(goal_tracker: Optional[str]) -> Tuple[List[Dict[str, str]], List[str]]:
    """Parse criteria, retaining only unambiguous stable criterion identities."""
    if not goal_tracker:
        return [], ["Acceptance Criteria section was missing or unreadable."]
    section = _first_heading_section(goal_tracker, "Acceptance Criteria")
    if section is None:
        return [], ["Acceptance Criteria section was missing."]

    parsed: List[Tuple[str, str]] = []
    problems: List[str] = []
    list_position = 0
    for line in section.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("<!--") or stripped.endswith("-->"):
            continue
        match = re.match(r"^(?:[-*]|[0-9]+[.)])\s+(.*)$", stripped)
        if not match:
            continue
        list_position += 1
        raw = match.group(1).strip()
        explicit = _EXPLICIT_AC_LABEL.match(raw)
        if explicit:
            identifier = _ac_id(explicit.group(1))
            text = explicit.group(2).strip()
        elif _looks_like_malformed_ac_label(raw):
            problems.append(
                f"Acceptance Criteria entry {list_position} has a malformed AC label."
            )
            continue
        else:
            identifier = f"ac-{list_position}"
            text = raw
        if not text:
            problems.append(
                f"Acceptance Criteria entry {list_position} has no criterion text."
            )
            continue
        parsed.append((identifier, text))

    identifiers = [identifier for identifier, _ in parsed]
    duplicate_ids = sorted(
        identifier for identifier in set(identifiers) if identifiers.count(identifier) > 1
    )
    if duplicate_ids:
        problems.append(
            "Acceptance Criteria contains duplicate labels or generated IDs: "
            + ", ".join(duplicate_ids)
            + "."
        )
    ambiguous_ids = set(duplicate_ids)
    criteria = [
        {
            "id": identifier,
            "text": text,
            "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        }
        for identifier, text in parsed
        if identifier not in ambiguous_ids
    ]
    if not parsed and not problems:
        problems.append("Acceptance Criteria section contained no list items.")
    return criteria, problems


def _ac_ids(raw: str) -> List[str]:
    """Return stable criterion IDs explicitly named in free-form table text."""
    identifiers: List[str] = []
    for match in _AC_REFERENCE.finditer(raw):
        identifier = _ac_id(match.group(1))
        if identifier not in identifiers:
            identifiers.append(identifier)
    return identifiers


def _ac_references(raw: str) -> Tuple[List[str], List[str]]:
    """Return valid AC IDs and any malformed AC-like references in the text."""
    identifiers = _ac_ids(raw)
    malformed: List[str] = []
    for match in _AC_REFERENCE_ATTEMPT.finditer(raw):
        token = match.group(0)
        if not re.fullmatch(r"AC-?[0-9]+(?::)?", token, flags=re.IGNORECASE):
            if token not in malformed:
                malformed.append(token)
    return identifiers, malformed


def _parse_table_rows(section: Optional[str]) -> List[List[str]]:
    if not section:
        return []
    rows: List[List[str]] = []
    for line in section.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or all(set(cell) <= {"-", ":", " "} for cell in cells):
            continue
        rows.append(cells)
    return rows


def _parse_completed_and_deferred(
    goal_tracker: Optional[str], known_ac_ids: Sequence[str]
) -> Tuple[set, List[Dict[str, str]], List[str]]:
    """Resolve completed/deferred table references against known stable AC IDs."""
    if not goal_tracker:
        return set(), [], []
    known = set(known_ac_ids)
    problems: List[str] = []
    completed_rows = _parse_table_rows(
        _first_heading_section(goal_tracker, "Completed and Verified")
    )
    completed: set = set()
    for row in completed_rows:
        if not row or row[0].lower() in ("ac", "acceptance criteria"):
            continue
        identifiers, malformed = _ac_references(row[0])
        if malformed:
            problems.append(
                "Completed and Verified contains malformed AC references: "
                + ", ".join(malformed)
                + "."
            )
        if not identifiers:
            continue
        unknown = sorted(identifier for identifier in identifiers if identifier not in known)
        if unknown:
            problems.append(
                "Completed and Verified references unknown Acceptance Criteria: "
                + ", ".join(unknown)
                + "."
            )
        completed.update(identifier for identifier in identifiers if identifier in known)

    deferred_rows = _parse_table_rows(_first_heading_section(goal_tracker, "Explicitly Deferred"))
    deferred: List[Dict[str, str]] = []
    for row in deferred_rows:
        if not row or row[0].lower() in ("task", "ac"):
            continue
        identifiers, malformed = _ac_references(" ".join(row[:2]))
        if malformed:
            problems.append(
                "Explicitly Deferred contains malformed AC references: "
                + ", ".join(malformed)
                + "."
            )
        if not identifiers:
            continue
        unknown = sorted(identifier for identifier in identifiers if identifier not in known)
        if unknown:
            problems.append(
                "Explicitly Deferred references unknown Acceptance Criteria: "
                + ", ".join(unknown)
                + "."
            )
        # The row's source evidence is the goal tracker itself.  Keep a stable
        # human-readable anchor rather than trying to parse free-form prose.
        for identifier in identifiers:
            if identifier in known:
                deferred.append({"ac_id": identifier, "detail": " | ".join(row)})
    return completed, deferred, problems


def _kind_for_path(relative_path: str) -> str:
    name = Path(relative_path).name
    if relative_path == "plan.md":
        return "plan"
    if relative_path == "goal-tracker.md":
        return "goal_tracker"
    if name.endswith("-state.md") or name in ("state.md", "finalize-state.md"):
        return "state"
    if re.fullmatch(r"round-[0-9]+-contract\.md", name):
        return "round_contract"
    if re.fullmatch(r"round-[0-9]+-summary\.md", name):
        return "round_summary"
    if re.fullmatch(r"round-[0-9]+-review-result\.md", name):
        return "round_review_result"
    if re.fullmatch(r"round-[0-9]+-review-prompt\.md", name):
        return "review_prompt"
    if re.fullmatch(r"round-[0-9]+-prompt\.md", name):
        return "prompt"
    if name == "finalize-summary.md":
        return "finalize_summary"
    if name == "methodology-analysis-report.md":
        return "methodology_analysis_report"
    if name == "methodology-analysis-done.md":
        return "methodology_analysis_done"
    if relative_path == ".loop/bitlesson.md" or relative_path.endswith("/.loop/bitlesson.md"):
        return "bitlesson"
    if name.endswith(".jsonl"):
        return "transcript"
    if name.endswith(".log"):
        return "log"
    return "unknown"


_RECOGNIZED_METADATA_PATHS = frozenset({".cancel-requested", ".review-phase-started"})


def _iter_files(run_dir: Path) -> Iterable[Tuple[str, Path]]:
    for path in sorted(run_dir.rglob("*")):
        # Do not follow a symlink out of the Run's read-only boundary.
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(run_dir).as_posix()
        if relative == ".DS_Store":
            continue
        yield relative, path


def _timestamp_or_none(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    # State timestamps are expected to already be UTC whole seconds.  Avoid
    # guessing or normalizing legacy values; an invalid value is a gap.
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
        return value
    return None


@dataclass
class RunRecord:
    """Internal, profile-independent representation of a terminal Run."""

    run_dir: Path
    terminal_state: str
    state_path: Path
    state: Dict[str, Any]
    plan_text: Optional[str]
    goal_tracker_text: Optional[str]
    goal: str
    acceptance_criteria: List[Dict[str, str]]
    ac_mapping_valid: bool = True
    completed_ac_ids: set = field(default_factory=set)
    deferred: List[Dict[str, str]] = field(default_factory=list)
    warnings: List[Dict[str, str]] = field(default_factory=list)
    rounds: List[Dict[str, Any]] = field(default_factory=list)
    events: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def session_timestamp(self) -> Optional[str]:
        return _timestamp_or_none(self.state.get("started_at"))

    @property
    def base_commit(self) -> Optional[str]:
        value = self.state.get("base_commit")
        return value if isinstance(value, str) and value else None

    @property
    def head_commit(self) -> Optional[str]:
        value = self.state.get("head_commit")
        return value if isinstance(value, str) and value else None

    @property
    def reviewed_commit(self) -> Optional[str]:
        value = self.state.get("reviewed_commit")
        return value if isinstance(value, str) and value else None


class RunAdapter:
    """Read-only adapter for existing Loop Run artifacts."""

    def __init__(self, run_dir: Union[str, os.PathLike[str]]) -> None:
        self.run_dir = Path(run_dir).expanduser().resolve()

    def terminal_state_path(self) -> Path:
        if not self.run_dir.exists() or not self.run_dir.is_dir():
            raise RunUnreadableError(f"Run directory does not exist: {self.run_dir}")
        terminal = []
        for path in self.run_dir.glob("*-state.md"):
            stem = path.name[: -len("-state.md")]
            if stem in TERMINAL_STATES:
                terminal.append(path)
        if terminal:
            return sorted(terminal, key=lambda item: item.name)[-1]
        active = [path.name for path in (self.run_dir / "state.md", self.run_dir / "finalize-state.md") if path.exists()]
        if active:
            raise ActiveRunError(
                f"the Run has not finished (active state file: {', '.join(active)})"
            )
        raise ActiveRunError(
            "the Run has not finished (no terminal state file: "
            + ", ".join(f"{state}-state.md" for state in sorted(TERMINAL_STATES))
            + ")"
        )

    def adapt(self) -> RunRecord:
        state_path = self.terminal_state_path()
        state = read_frontmatter(state_path)
        terminal_state = state_path.name[: -len("-state.md")]
        plan_path = self.run_dir / "plan.md"
        tracker_path = self.run_dir / "goal-tracker.md"
        plan_text = _read_text(plan_path)
        tracker_text = _read_text(tracker_path)
        warnings: List[Dict[str, str]] = []
        if plan_text is None:
            warnings.append(
                {"reason": "missing-file", "target": "plan.md", "detail": "plan.md is missing or unreadable."}
            )
        if tracker_text is None:
            warnings.append(
                {"reason": "missing-file", "target": "goal-tracker.md", "detail": "goal-tracker.md is missing or unreadable."}
            )
        criteria, criteria_problems = _parse_criteria(tracker_text)
        if criteria_problems:
            warnings.append(
                {
                    "reason": "unparseable-artifact",
                    "target": "goal-tracker.md",
                    "detail": " ".join(criteria_problems),
                }
            )
        goal = ""
        if plan_text:
            goal_section = _first_heading_section(plan_text, "Goal")
            goal = (goal_section or "").strip()
            if not goal:
                first_heading = re.search(r"^#\s+(.+?)\s*$", plan_text, flags=re.MULTILINE)
                goal = first_heading.group(1).strip() if first_heading else ""
        completed, deferred, table_problems = _parse_completed_and_deferred(
            tracker_text, [criterion["id"] for criterion in criteria]
        )
        if table_problems:
            warnings.append(
                {
                    "reason": "unparseable-artifact",
                    "target": "goal-tracker.md",
                    "detail": " ".join(table_problems),
                }
            )
        if not self._has_any_state_fact(state, ("head_commit", "reviewed_commit", "ended_at")):
            warnings.append(
                {
                    "reason": "legacy-version-gap",
                    "target": state_path.name,
                    "detail": "Run Recorder facts head_commit/reviewed_commit/ended_at are absent; values remain null.",
                }
            )
        rounds, events = self._rounds_and_events(_timestamp_or_none(state.get("ended_at")))
        return RunRecord(
            run_dir=self.run_dir,
            terminal_state=terminal_state,
            state_path=state_path,
            state=state,
            plan_text=plan_text,
            goal_tracker_text=tracker_text,
            goal=goal,
            acceptance_criteria=criteria,
            ac_mapping_valid=not criteria_problems and not table_problems,
            completed_ac_ids=completed,
            deferred=deferred,
            warnings=warnings,
            rounds=rounds,
            events=events,
        )

    @staticmethod
    def _has_any_state_fact(state: Mapping[str, Any], names: Sequence[str]) -> bool:
        return any(state.get(name) not in (None, "") for name in names)

    def _rounds_and_events(self, ended_at: Optional[str]) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        indexes = set()
        completed_artifact = re.compile(
            r"round-([0-9]+)-(?:contract|summary|review-result)\.md$"
        )
        for path in self.run_dir.iterdir() if self.run_dir.exists() else []:
            match = completed_artifact.match(path.name)
            if match:
                indexes.add(int(match.group(1)))
        rounds = [{"index": index} for index in sorted(indexes)]
        events: List[Dict[str, Any]] = [{"kind": "setup", "at": None}]
        for index in sorted(indexes):
            # The v0 event schema deliberately exposes only ``kind`` and
            # ``at``. The chronological order already carries the round
            # relationship, so avoid emitting our own unknown extensions.
            events.append({"kind": "round", "at": None})
            review = self.run_dir / f"round-{index}-review-result.md"
            text = _read_text(review)
            if text:
                verdict = re.search(
                    r"Mainline Progress Verdict:\s*(ADVANCED|STALLED|REGRESSED)",
                    text,
                    flags=re.IGNORECASE,
                )
                if verdict:
                    events.append(
                        {
                            "kind": "mainline_verdict",
                            "at": None,
                        }
                    )
        if (self.run_dir / ".review-phase-started").exists():
            events.append({"kind": "review_phase", "at": None})
        if (self.run_dir / "finalize-summary.md").exists():
            events.append({"kind": "finalize", "at": None})
        events.append({"kind": "terminal", "at": ended_at})
        return rounds, events


def _default_profile(name: str) -> Dict[str, Any]:
    if re.fullmatch(r"[a-z][a-z0-9-]*-v[0-9]+", name):
        path = Path(__file__).resolve().parent / "profiles" / f"{name}.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    raise ProofError(f"unknown verification profile {name!r}")


def load_profile(name: str = "public-v0") -> Dict[str, Any]:
    """Load a profile document and fail closed when it is malformed."""
    profile = _default_profile(name)
    result = validate_instance(profile, load_schema("verification-profile-v0"))
    if not result.is_valid:
        detail = "; ".join(f"{issue.path}: {issue.message}" for issue in result.errors)
        raise ProofError(f"invalid verification profile {name!r}: {detail}")
    return profile


def _profile_hash(profile: Mapping[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(canonical_json_bytes(dict(profile))).hexdigest()


def _bundle_document_bytes(bundle: Mapping[str, Any]) -> Tuple[bytes, bytes]:
    """Render the two manifest-derived Bundle files in their write format."""
    proof_json = (
        json.dumps(bundle, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    proof_data = (
        "window.PROOF = "
        + json.dumps(bundle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + ";\n"
    ).encode("utf-8")
    return proof_json, proof_data


def _deterministic_managed_bundle_bytes(
    bundle: Mapping[str, Any], published_evidence_bytes: int
) -> int:
    """Measure generated Bundle files without mutable transport metadata."""
    projection = dict(bundle)
    projection.pop("transport", None)
    proof_json, proof_data = _bundle_document_bytes(projection)
    return len(proof_json) + len(proof_data) + published_evidence_bytes


def _size_budget_warning(
    profile: Mapping[str, Any], bundle: Mapping[str, Any], published_evidence_bytes: int
) -> Optional[Dict[str, str]]:
    """Return a stable size warning from the pre-warning managed output.

    The rendered manifests count toward the bundle budget, while transport does
    not: it is outside Proof identity and would make this canonical warning vary
    by host or export time.
    """
    max_bundle_bytes = profile.get("max_bundle_bytes")
    managed_bundle_bytes = _deterministic_managed_bundle_bytes(
        bundle, published_evidence_bytes
    )
    if (
        isinstance(max_bundle_bytes, bool)
        or not isinstance(max_bundle_bytes, int)
        or max_bundle_bytes < 0
        or managed_bundle_bytes <= max_bundle_bytes
    ):
        return None
    return {
        "reason": "size-budget-exceeded",
        "target": "bundle",
        "detail": (
            f"Deterministic managed Bundle output is {managed_bundle_bytes} bytes, exceeding "
            f"max_bundle_bytes ({max_bundle_bytes})."
        ),
    }


def _bundle_without_size_budget_warning(bundle: Mapping[str, Any]) -> Dict[str, Any]:
    """Return the compiler's pre-warning candidate for deterministic rechecks."""
    candidate = dict(bundle)
    integrity = dict(candidate.get("integrity", {}))
    integrity["compile_warnings"] = [
        warning
        for warning in integrity.get("compile_warnings", [])
        if warning.get("reason") != "size-budget-exceeded"
    ]
    candidate["integrity"] = integrity
    candidate["proof_id"] = compute_proof_id(candidate)
    return candidate


def _reviewed_head_warning(
    profile: Mapping[str, Any], head_commit: Optional[str], reviewed_commit: Optional[str]
) -> Optional[Dict[str, str]]:
    """Return the badge-only review coverage warning required by a profile."""
    if (
        profile.get("require_reviewed_equals_head") is not True
        or not head_commit
        or not reviewed_commit
        or reviewed_commit == head_commit
    ):
        return None
    return {
        "reason": "reviewed-commit-behind-head",
        "target": "source.reviewed_commit",
        "detail": "Reviewed commit differs from the final head commit; badge is withheld.",
    }


def _utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _evidence_id(path: str, digest: str) -> str:
    payload = canonical_json_bytes({"path": path, "sha256": digest})
    return hashlib.sha256(payload).hexdigest()[:16]


def _evidence_full_id(path: str, digest: str) -> str:
    """Return the collision-extension form of the D4 Evidence ID."""
    return hashlib.sha256(
        canonical_json_bytes({"path": path, "sha256": digest})
    ).hexdigest()


def _safe_relative_evidence_path(relative: Any) -> bool:
    """Reject traversal and platform-specific path escapes before filesystem I/O."""
    if not isinstance(relative, str) or not relative or "\x00" in relative:
        return False
    # Bundles use POSIX paths regardless of the host that produced them.
    if "\\" in relative or relative.startswith("/"):
        return False
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    candidate = Path(relative)
    return not candidate.is_absolute() and ".." not in candidate.parts


def _has_absolute_path(data: bytes) -> bool:
    text = data.decode("utf-8", errors="replace")
    return bool(re.search(r"(?<![A-Za-z0-9._-])/(?:Users|home)/[^\s/]+", text))


def _contains_absolute_home_path(value: Any) -> bool:
    """Return whether a JSON-shaped value exposes an absolute home path."""
    if isinstance(value, str):
        return _has_absolute_path(value.encode("utf-8"))
    if isinstance(value, list):
        return any(_contains_absolute_home_path(item) for item in value)
    if isinstance(value, dict):
        return any(_contains_absolute_home_path(item) for item in value.values())
    return False


def _profile_omits_evidence(
    relative_path: str, kind: str, profile: Mapping[str, Any]
) -> bool:
    """Return whether a profile unconditionally withholds one file evidence item."""
    omit_kinds = set(profile.get("omit_kinds", []))
    omit_paths = list(profile.get("omit_paths", []))
    return kind in omit_kinds or any(
        fnmatch.fnmatch(relative_path, pattern) for pattern in omit_paths
    )


_SECRET_PATTERNS: Tuple[Tuple[str, re.Pattern[str]], ...] = (
    ("pem-header", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("cloud-credential", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9_]{20,}\b")),
    (
        "token-assignment",
        re.compile(
            r"(?<![A-Za-z0-9])(?:[A-Za-z0-9]+_)*(?:token|api[_-]?key|secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9_\-]{8,}",
            re.IGNORECASE,
        ),
    ),
)
_URL_SAFE_CANDIDATE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"
)
_STANDARD_BASE64_CANDIDATE = re.compile(
    r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{32,}(?:={1,2})?(?![A-Za-z0-9+/=])"
)


def _shannon_entropy(value: str) -> float:
    """Return the Shannon entropy of a candidate without exposing its value."""
    if not value:
        return 0.0
    counts: Dict[str, int] = {}
    for character in value:
        counts[character] = counts.get(character, 0) + 1
    length = len(value)
    return -sum(
        (count / length) * math.log2(count / length)
        for count in sorted(counts.values())
    )


def _has_high_entropy_candidate(text: str) -> bool:
    """Detect a credential-like Base64 or URL-safe token conservatively."""
    for pattern in (_URL_SAFE_CANDIDATE, _STANDARD_BASE64_CANDIDATE):
        for match in pattern.finditer(text):
            candidate = match.group(0).rstrip("=")
            candidates = [candidate] + candidate.split("/")
            for value in candidates:
                if len(value) >= 32 and _shannon_entropy(value) >= 4.5:
                    return True
    return False


def _secret_match(data: bytes, enabled: Sequence[str]) -> Optional[str]:
    if not enabled:
        return None
    text = data.decode("utf-8", errors="replace")
    for kind, pattern in _SECRET_PATTERNS:
        if kind in enabled and pattern.search(text):
            return kind
    if "high-entropy" in enabled and _has_high_entropy_candidate(text):
        return "high-entropy"
    return None


@dataclass
class EvidenceCollection:
    items: List[Dict[str, Any]]
    contents: Dict[str, bytes]
    disclosure: List[Dict[str, str]]
    warnings: List[Dict[str, str]]


class EvidenceCompiler:
    """Collect raw-byte evidence and create profile declarations."""

    def __init__(self, run: RunRecord, profile: Mapping[str, Any]) -> None:
        self.run = run
        self.profile = profile

    def collect(self) -> EvidenceCollection:
        items: List[Dict[str, Any]] = []
        contents: Dict[str, bytes] = {}
        disclosure: List[Dict[str, str]] = []
        warnings: List[Dict[str, str]] = []
        used_ids: Dict[str, str] = {}
        secret_scan = self.profile.get("secret_scan", {}) or {}
        fail_on = list(secret_scan.get("fail_on", []))
        omit_on = set(secret_scan.get("omit_on", []))
        max_item_bytes = self.profile.get("max_item_bytes")
        if not isinstance(max_item_bytes, int) or max_item_bytes < 0:
            max_item_bytes = 1048576

        for relative, source_path in _iter_files(self.run.run_dir):
            try:
                data = source_path.read_bytes()
            except OSError as error:
                warnings.append({"reason": "missing-file", "target": relative, "detail": str(error)})
                continue
            digest = hashlib.sha256(data).hexdigest()
            kind = _kind_for_path(relative)
            if kind == "unknown" and relative not in _RECOGNIZED_METADATA_PATHS:
                warnings.append(
                    {
                        "reason": "unparseable-artifact",
                        "target": relative,
                        "detail": "Unrecognized source artifact retained as evidence kind 'unknown'.",
                    }
                )
            identifier = _evidence_id(relative, digest)
            if identifier in used_ids and used_ids[identifier] != relative:
                identifier = hashlib.sha256(canonical_json_bytes({"path": relative, "sha256": digest})).hexdigest()
            used_ids[identifier] = relative
            item: Dict[str, Any] = {
                "id": identifier,
                "path": relative,
                "sha256": digest,
                "bytes": len(data),
                "kind": kind,
                "status": "included",
                "omitted_reason": None,
            }
            omit_reason: Optional[str] = None
            if _profile_omits_evidence(relative, kind, self.profile):
                omit_reason = "profile-redaction"
            elif "absolute-path" in omit_on and _has_absolute_path(data):
                omit_reason = "absolute-path"
                warnings.append(
                    {
                        "reason": "redacted-by-profile",
                        "target": relative,
                        "detail": "Absolute local path detected; evidence omitted by profile.",
                    }
                )
            # Omitted evidence bytes never enter the Bundle.  Scan every item
            # that can be published (including a later truncated item), while
            # allowing the profile to withhold sensitive source-only artifacts.
            if omit_reason is None:
                match = _secret_match(data, fail_on)
                if match:
                    raise SecretScanError(relative, match)
            if omit_reason:
                item["status"] = "omitted"
                item["omitted_reason"] = omit_reason
                disclosure.append({"path": relative, "reason": omit_reason})
            elif len(data) > max_item_bytes:
                item["status"] = "truncated"
                item["omitted_reason"] = "size-limit"
                warnings.append(
                    {
                        "reason": "truncated-evidence",
                        "target": relative,
                        "detail": f"Evidence exceeds max_item_bytes ({max_item_bytes}).",
                    }
                )
                # A truncated item has no verifiable raw file in the bundle.
            else:
                contents[relative] = data
            items.append(item)

        collisions: Dict[str, set] = {}
        for item in items:
            short_id = _evidence_id(item["path"], item["sha256"])
            collisions.setdefault(short_id, set()).add((item["path"], item["sha256"]))
        for item in items:
            short_id = _evidence_id(item["path"], item["sha256"])
            if len(collisions[short_id]) > 1:
                item["id"] = _evidence_full_id(item["path"], item["sha256"])

        for required_kind in self.profile.get("required_evidence_kinds", []):
            matching = [
                item
                for item in items
                if item["kind"] == required_kind and item["status"] == "included"
            ]
            if not matching:
                warnings.append(
                    {
                        "reason": "profile-required-evidence-missing",
                        "target": required_kind,
                        "detail": f"No evidence item of required kind {required_kind!r} was included.",
                    }
                )
        return EvidenceCollection(items, contents, disclosure, warnings)


_FINDING_MARKER = re.compile(
    r"^.{0,9}?(?P<marker>\[P(?P<severity>[0-9])\])\s+(?P<summary>.+?)\s*$",
    re.MULTILINE,
)
_FINDING_MARKER_ATTEMPT = re.compile(
    r"^.{0,9}?(?P<marker>\[P[^\]]*\])", re.MULTILINE
)


def _finding_key(severity: str, summary: str) -> str:
    """Return a stable internal key without exposing review prose in the Bundle."""
    normalized = re.sub(r"\s+", " ", summary.strip().lower())
    return f"{severity}:{normalized}"


def _append_unique(values: List[str], value: str) -> None:
    if value not in values:
        values.append(value)


def _derive_findings(
    run: RunRecord, evidence_by_path: Mapping[str, Mapping[str, Any]]
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]], bool]:
    """Derive conservative finding lifecycle facts from retained review results."""
    findings: List[Dict[str, Any]] = []
    warnings: List[Dict[str, str]] = []
    parseable = True
    active: Dict[str, Dict[str, Any]] = {}
    known_ac_ids = {criterion["id"] for criterion in run.acceptance_criteria}

    review_paths = [
        (
            round_data["index"],
            f"round-{round_data['index']}-review-result.md",
            run.run_dir / f"round-{round_data['index']}-review-result.md",
        )
        for round_data in run.rounds
    ]

    for round_index, relative, path in sorted(review_paths):
        item = evidence_by_path.get(relative)
        if not item or item.get("status") != "included":
            if item is None and not active:
                # A Run can record early contract/summary artifacts before it
                # produces its first review result. Without an active finding,
                # that absence is not a failed re-review to resolve.
                continue
            # A profile cannot use source content it did not retain to make a
            # finding judgment. One included review result of the required kind
            # is not enough to establish that a later unavailable review did not
            # contain an unresolved finding.
            parseable = False
            status = item.get("status", "missing") if item else "missing"
            warnings.append(
                {
                    "reason": "unparseable-artifact",
                    "target": relative,
                    "detail": "Review result was "
                    + status
                    + "; finding lifecycle is unverifiable.",
                }
            )
            for finding in active.values():
                finding["status"] = "unverifiable"
                if item and item.get("id"):
                    _append_unique(finding["evidence_refs"], item["id"])
            active = {}
            continue
        text = _read_text(path)
        if text is None or not text.strip():
            parseable = False
            warnings.append(
                {
                    "reason": "unparseable-artifact",
                    "target": relative,
                    "detail": "Review result was unreadable or empty; finding lifecycle is unverifiable.",
                }
            )
            for finding in active.values():
                finding["status"] = "unverifiable"
                _append_unique(finding["evidence_refs"], item["id"])
            active = {}
            continue

        marker_matches = list(_FINDING_MARKER.finditer(text))
        valid_marker_spans = {
            (match.start("marker"), match.end("marker")) for match in marker_matches
        }
        malformed_markers = []
        for marker in _FINDING_MARKER_ATTEMPT.finditer(text):
            token = marker.group("marker")
            span = (marker.start("marker"), marker.end("marker"))
            if span not in valid_marker_spans and token not in malformed_markers:
                malformed_markers.append(token)
        if malformed_markers:
            parseable = False
            warnings.append(
                {
                    "reason": "unparseable-artifact",
                    "target": relative,
                    "detail": "Review result contains malformed finding markers: "
                    + ", ".join(malformed_markers)
                    + ".",
                }
            )

        current: Dict[str, Tuple[str, List[str]]] = {}
        for marker in marker_matches:
            severity = f"P{marker.group('severity')}"
            summary = marker.group("summary")
            key = _finding_key(severity, summary)
            ac_refs = [identifier for identifier in _ac_ids(marker.group(0)) if identifier in known_ac_ids]
            if key not in current:
                current[key] = (severity, ac_refs)
            else:
                for identifier in ac_refs:
                    _append_unique(current[key][1], identifier)

        if malformed_markers:
            for finding in active.values():
                finding["status"] = "unverifiable"
                _append_unique(finding["evidence_refs"], item["id"])
            active = {}
        else:
            for key, finding in active.items():
                if key not in current:
                    finding["status"] = "resolved"
                    _append_unique(finding["evidence_refs"], item["id"])
            next_active: Dict[str, Dict[str, Any]] = {}
            for key, (severity, ac_refs) in current.items():
                finding = active.get(key)
                if finding is None:
                    identifier = "finding-" + hashlib.sha256(
                        canonical_json_bytes(
                            {
                                "round": round_index,
                                "severity": severity,
                                "key": key,
                            }
                        )
                    ).hexdigest()[:16]
                    finding = {
                        "id": identifier,
                        "severity": severity,
                        "status": "open",
                        "found_round": round_index,
                        "evidence_refs": [item["id"]],
                        "ac_refs": ac_refs,
                    }
                    findings.append(finding)
                else:
                    _append_unique(finding["evidence_refs"], item["id"])
                    for ac_id in ac_refs:
                        _append_unique(finding["ac_refs"], ac_id)
                next_active[key] = finding
            active = next_active

    return findings, warnings, parseable


def _repo_name(repo_root: Optional[Union[str, os.PathLike[str]]], fallback: Path) -> str:
    if repo_root:
        return Path(repo_root).resolve().name
    for candidate in (fallback, *fallback.parents):
        if (candidate / ".git").exists():
            return candidate.name
    return fallback.parent.name


def _utc_timestamp(raw: str) -> str:
    """Normalize Git's author timestamp to the canonical UTC representation."""
    try:
        parsed = _datetime.datetime.fromisoformat(raw)
        if parsed.tzinfo is None:
            return raw
        return (
            parsed.astimezone(_datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except (TypeError, ValueError):
        # Git's ``%aI`` is ISO-8601, but preserving an unexpected value lets
        # schema validation report the malformed derived record explicitly.
        return raw


_GIT_COMMIT_ID = re.compile(r"^[0-9a-f]{7,64}$")


def _git_commit_records(
    repo_root: Optional[Union[str, os.PathLike[str]]],
    base_commit: Optional[str],
    head_commit: Optional[str],
) -> List[Dict[str, str]]:
    """Read the immutable commit range without making Git or filesystem changes.

    A Run may be copied away from its original repository, or its recorded
    commits may predate a shallow clone.  In those cases the derived record is
    simply unavailable; file evidence and the profile-relative verdict remain
    usable.  We deliberately do not guess a commit range from the current
    checkout.
    """
    if (
        not repo_root
        or not isinstance(base_commit, str)
        or not isinstance(head_commit, str)
        or _GIT_COMMIT_ID.fullmatch(base_commit) is None
        or _GIT_COMMIT_ID.fullmatch(head_commit) is None
    ):
        return []
    repository = Path(repo_root).expanduser().resolve()
    if not (repository / ".git").exists():
        return []
    format_spec = "%H%x00%s%x00%aI%x00%an%x00%ae"
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(repository),
                "log",
                "--reverse",
                "-z",
                "--encoding=UTF-8",
                f"--format={format_spec}",
                "--end-of-options",
                f"{base_commit}..{head_commit}",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError:
        return []
    if result.returncode != 0:
        return []

    fields = result.stdout.split("\x00")
    if fields and fields[-1] == "":
        fields.pop()
    if len(fields) % 5:
        raise ProofError("cannot parse Git commit metadata safely")

    records: List[Dict[str, str]] = []
    for offset in range(0, len(fields), 5):
        sha, subject, authored_at, author_name, author_email = fields[offset : offset + 5]
        if _GIT_COMMIT_ID.fullmatch(sha) is None:
            raise ProofError("cannot parse Git commit metadata safely")
        records.append(
            {
                "sha": sha,
                "subject": subject,
                "authored_at": _utc_timestamp(authored_at),
                "author_name": author_name,
                "author_email": author_email,
            }
        )
    return records


def _scan_derived_commit_records(
    records: Sequence[Mapping[str, Any]], profile: Mapping[str, Any]
) -> None:
    """Fail closed when public commit metadata contains a secret-class match."""
    secret_scan = profile.get("secret_scan", {}) or {}
    fail_on = list(secret_scan.get("fail_on", []))
    for record in records:
        match = _secret_match(canonical_json_bytes(dict(record)), fail_on)
        if match:
            target = "commit:" + str(record.get("sha", "unknown"))
            raise SecretScanError(target, match)


def _redact_derived_fields(
    records: Sequence[Mapping[str, Any]], profile: Mapping[str, Any]
) -> List[Dict[str, Any]]:
    """Apply profile-declared field redactions to derived commit records."""
    fields = {
        entry.get("field")
        for entry in profile.get("field_redactions", [])
        if isinstance(entry, Mapping)
    }
    redacted: List[Dict[str, Any]] = []
    for record in records:
        projected = dict(record)
        if "commit.author_email" in fields:
            projected.pop("author_email", None)
        redacted.append(projected)
    return redacted


class BundleCompiler:
    """Compile one terminal Run into a schema-valid Proof Bundle mapping."""

    def __init__(
        self,
        run_dir: Union[str, os.PathLike[str]],
        profile: str = "public-v0",
        repo_root: Optional[Union[str, os.PathLike[str]]] = None,
        exporter_version: str = "proof-mvp-v0",
    ) -> None:
        self.adapter = RunAdapter(run_dir)
        self.profile_name = profile
        self.repo_root = Path(repo_root).resolve() if repo_root else None
        self.exporter_version = exporter_version

    def compile(self) -> Tuple[Dict[str, Any], EvidenceCollection]:
        run = self.adapter.adapt()
        profile = load_profile(self.profile_name)
        profile_omit_on = set((profile.get("secret_scan", {}) or {}).get("omit_on", []))
        evidence = EvidenceCompiler(run, profile).collect()
        evidence_by_path = {item["path"]: item for item in evidence.items}
        warnings = list(run.warnings) + list(evidence.warnings)
        published_evidence_bytes = sum(len(content) for content in evidence.contents.values())
        state_relative_path = run.state_path.relative_to(run.run_dir).as_posix()
        state_omitted = (
            evidence_by_path.get(state_relative_path, {}).get("status") == "omitted"
        )
        tracker_included = (
            evidence_by_path.get("goal-tracker.md", {}).get("status") == "included"
        )
        tracker_omitted = (
            evidence_by_path.get("goal-tracker.md", {}).get("status") == "omitted"
        )
        # Goal and acceptance-criteria text are projections of file evidence.
        # Once the source item is withheld, retaining those projections would
        # allow an absolute home path to bypass the profile's disclosure rule.
        projected_goal = (
            run.goal
            if evidence_by_path.get("plan.md", {}).get("status") != "omitted"
            else ""
        )
        projected_criteria = run.acceptance_criteria if not tracker_omitted else []
        projected_events = (
            run.events
            if not state_omitted
            else [{**event, "at": None} for event in run.events]
        )
        source = {
            "repo_name": _repo_name(self.repo_root, run.run_dir),
            "base_commit": run.base_commit,
            "head_commit": run.head_commit,
            "reviewed_commit": run.reviewed_commit,
            "loop_version": str(run.state.get("loop_version") or "unknown")
            if not state_omitted
            else "unknown",
            "exporter_version": self.exporter_version,
        }
        commits = _redact_derived_fields(
            _git_commit_records(
                self.repo_root,
                run.base_commit,
                run.head_commit,
            ),
            profile,
        )
        _scan_derived_commit_records(commits, profile)
        if run.head_commit is None:
            warnings.append(
                {"reason": "head-commit-unknown", "target": "source.head_commit", "detail": "Head commit was not recorded by the Run."}
            )
        reviewed_head_warning = _reviewed_head_warning(
            profile, run.head_commit, run.reviewed_commit
        )
        if run.reviewed_commit is None:
            warnings.append(
                {"reason": "reviewed-commit-unknown", "target": "source.reviewed_commit", "detail": "Reviewed commit was not recorded by the Run."}
            )
        elif reviewed_head_warning is not None:
            warnings.append(reviewed_head_warning)

        def evidence_refs_for_path(path: str) -> List[str]:
            item = evidence_by_path.get(path)
            return [item["id"]] if item and item["status"] == "included" else []

        tracker_ref = evidence_refs_for_path("goal-tracker.md")
        review_refs = [
            item["id"]
            for item in evidence.items
            if item["kind"] == "round_review_result" and item["status"] == "included"
        ]
        summary_refs = [
            item["id"]
            for item in evidence.items
            if item["kind"] == "round_summary" and item["status"] == "included"
        ]
        findings, finding_warnings, findings_parseable = _derive_findings(
            run, evidence_by_path
        )
        if tracker_omitted:
            # Without the Goal Tracker, finding-to-AC links are not
            # profile-verifiable.  Keep the finding lifecycle facts, but do
            # not emit dangling acceptance-criterion references.
            for finding in findings:
                finding["ac_refs"] = []
        warnings.extend(finding_warnings)
        open_finding_refs: Dict[str, List[str]] = {}
        unverifiable_finding_refs: Dict[str, List[str]] = {}
        for finding in findings:
            status = finding["status"]
            if status not in ("open", "unverifiable"):
                continue
            target = (
                open_finding_refs if status == "open" else unverifiable_finding_refs
            )
            for ac_id in finding["ac_refs"]:
                target.setdefault(ac_id, [])
                for identifier in finding["evidence_refs"]:
                    _append_unique(target[ac_id], identifier)
        per_ac: List[Dict[str, Any]] = []
        deferred_output: List[Dict[str, str]] = []
        deferred_ac_ids = {item["ac_id"] for item in run.deferred}
        for criterion in projected_criteria:
            ac_id = criterion["id"]
            completed = ac_id in run.completed_ac_ids
            supporting = tracker_ref + review_refs + summary_refs if completed and tracker_ref else []
            if completed and tracker_ref:
                status = "met"
                reason = "Recorded in the Completed and Verified table."
            elif completed:
                status = "unverifiable"
                reason = "Completion evidence is unavailable in this verification profile."
            elif run.terminal_state != "complete":
                status = "unmet"
                reason = "Run ended before this criterion was recorded as completed."
            else:
                status = "unverifiable"
                reason = "No structured completion record was found."
            contradicting: List[str] = []
            if ac_id in deferred_ac_ids:
                if tracker_ref:
                    status = "deferred"
                    reason = "Criterion was explicitly deferred in the Goal Tracker."
                    deferred_output.append({"ac_id": ac_id, "replan_ref": tracker_ref[0]})
                else:
                    status = "unverifiable"
                    reason = "Deferral evidence is unavailable in this verification profile."
            elif ac_id in unverifiable_finding_refs:
                status = "unverifiable"
                reason = "A finding associated with this criterion could not be verified."
                contradicting = unverifiable_finding_refs[ac_id]
            elif ac_id in open_finding_refs:
                status = "partial" if status == "met" else "unmet"
                reason = "An unresolved finding is associated with this criterion."
                contradicting = open_finding_refs[ac_id]
            per_ac.append(
                {
                    "ac_id": ac_id,
                    "status": status,
                    "reason": reason,
                    "supporting": supporting,
                    "contradicting": contradicting,
                }
            )

        required_set = [criterion["id"] for criterion in projected_criteria if criterion["id"] not in {item["ac_id"] for item in deferred_output}]
        required_statuses = [item["status"] for item in per_ac if item["ac_id"] in required_set]
        required_profile_evidence_present = all(
            any(
                item["kind"] == required_kind
                and item["status"] == "included"
                for item in evidence.items
            )
            for required_kind in profile.get("required_evidence_kinds", [])
        )
        has_open_finding = any(finding["status"] == "open" for finding in findings)
        has_unverifiable_finding = any(
            finding["status"] == "unverifiable" for finding in findings
        )
        if run.terminal_state != "complete":
            decision = "changes_required"
        elif not run.ac_mapping_valid or not findings_parseable:
            decision = "unverifiable"
        elif not required_profile_evidence_present or not required_statuses:
            decision = "unverifiable"
        elif any(status == "unverifiable" for status in required_statuses):
            decision = "unverifiable"
        elif any(status in ("partial", "unmet") for status in required_statuses):
            decision = "changes_required"
        elif has_unverifiable_finding:
            decision = "unverifiable"
        elif has_open_finding:
            decision = "changes_required"
        elif all(status == "met" for status in required_statuses):
            decision = "accept"
        else:
            decision = "unverifiable"

        bundle: Dict[str, Any] = {
            "schema_version": "proof-bundle-v0",
            "proof_id": "sha256:" + "0" * 64,
            "run_id": compute_run_id(
                {
                    "base_commit": run.base_commit,
                    "head_commit": run.head_commit,
                    "session_timestamp": run.session_timestamp,
                    "terminal_state": run.terminal_state,
                    "round_indices": [round_data["index"] for round_data in run.rounds],
                }
            ),
            "profile": {
                "name": profile["name"],
                "version": profile["version"],
                "schema_hash": _profile_hash(profile),
            },
            "source": source,
            "specification": {"goal": projected_goal, "acceptance_criteria": projected_criteria},
            "run": {
                "session_timestamp": run.session_timestamp if not state_omitted else None,
                "terminal_state": run.terminal_state,
                "rounds": run.rounds,
                "events": projected_events,
            },
            "evidence": evidence.items,
            "commits": commits,
            "findings": findings,
            "verdict": {
                "decision": decision,
                "per_ac": per_ac,
                "required_set": required_set,
                "deferred": deferred_output,
            },
            "integrity": {"compile_warnings": warnings},
            "disclosure": {"omitted": evidence.disclosure, "field_redactions": list(profile.get("field_redactions", []))},
            "transport": {"exported_at": _utc_now(), "exporter_host_class": platform.system().lower() or "unknown"},
        }
        if "absolute-path" in profile_omit_on and _contains_absolute_home_path(bundle):
            raise ProofError(
                "profile projection contains an absolute home path"
            )
        bundle["proof_id"] = compute_proof_id(bundle)
        size_warning = _size_budget_warning(
            profile, bundle, published_evidence_bytes
        )
        if size_warning is not None:
            warnings.append(size_warning)
            bundle["proof_id"] = compute_proof_id(bundle)
        schema_result = validate_instance(bundle, load_schema("proof-bundle-v0"))
        if not schema_result.is_valid:
            detail = "; ".join(f"{issue.path}: {issue.message}" for issue in schema_result.errors)
            raise ProofError(f"compiler produced an invalid Proof Bundle: {detail}")
        return bundle, evidence


def _is_existing_proof_bundle(path: Path) -> bool:
    """Return whether a non-empty output directory is a managed Proof Bundle."""
    try:
        document = json.loads((path / "proof.json").read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            return False
        schema_result = validate_instance(document, load_schema("proof-bundle-v0"))
        return schema_result.is_valid and document.get("proof_id") == compute_proof_id(
            document
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        return False


def write_bundle(
    bundle: Mapping[str, Any],
    evidence: EvidenceCollection,
    output_dir: Union[str, os.PathLike[str]],
) -> Path:
    """Write canonical ``proof.json`` and included raw evidence safely."""
    target = Path(output_dir).expanduser().resolve()
    try:
        if target.exists():
            if not target.is_dir():
                raise BundleWriteError(
                    f"Proof Bundle output is not a directory: {target}"
                )
            if any(target.iterdir()):
                if not _is_existing_proof_bundle(target):
                    raise BundleWriteError(
                        "Proof Bundle output must be empty or an existing Proof Bundle: "
                        f"{target}"
                    )
                # This is an explicitly reusable Proof Bundle directory, so
                # replace all of its generated files rather than leaving raw
                # evidence from a fuller profile behind.
                shutil.rmtree(target)
        target.mkdir(parents=True, exist_ok=True)
        evidence_root = target / "evidence"
        proof_path = target / "proof.json"
        proof_json, proof_data = _bundle_document_bytes(bundle)
        proof_path.write_bytes(proof_json)
        (target / "proof-data.js").write_bytes(proof_data)
        for relative, content in evidence.contents.items():
            destination = evidence_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
    except OSError as error:
        raise BundleWriteError(f"cannot write Proof Bundle {target}: {error}") from error
    return target


def find_latest_terminal_run(
    runs_dir: Union[str, os.PathLike[str]],
) -> Path:
    """Find the newest terminal Run directory by its sortable session name.

    The adapter, rather than the caller, remains the authority on whether a
    directory has a terminal state file.  Directory names are sorted rather
    than mtimes so copying a historical Run cannot change ``--latest``.
    """
    root = Path(runs_dir).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise RunUnreadableError(f"Run directory root does not exist: {root}")
    candidates: List[Path] = []
    for candidate in root.iterdir():
        if not candidate.is_dir():
            continue
        try:
            RunAdapter(candidate).terminal_state_path()
        except (ActiveRunError, RunUnreadableError):
            continue
        candidates.append(candidate)
    if not candidates:
        raise RunUnreadableError(f"No terminal Runs found under {root}")
    return sorted(candidates, key=lambda item: item.name, reverse=True)[0]


def default_output_dir(
    repo_root: Union[str, os.PathLike[str]], bundle: Mapping[str, Any]
) -> Path:
    """Return the documented identity-addressed default Bundle directory."""
    proof_id = bundle.get("proof_id")
    if not isinstance(proof_id, str) or not proof_id.startswith("sha256:"):
        raise ProofError("cannot derive a default output path without a proof_id")
    return Path(repo_root).expanduser().resolve() / ".loop" / "proofs" / proof_id.split(":", 1)[1][:12]


def _output_outside_run(
    run_dir: Union[str, os.PathLike[str]], output_dir: Union[str, os.PathLike[str]]
) -> Path:
    """Resolve and reject an output path nested inside the source Run."""
    source = Path(run_dir).expanduser().resolve()
    target = Path(output_dir).expanduser().resolve()
    try:
        target.relative_to(source)
    except ValueError:
        return target
    raise BundleWriteError(
        "Proof Bundle output must be outside the source Run to keep export read-only: "
        f"{target}"
    )


@dataclass
class ExportResult:
    """The identity and output location produced by one export."""

    bundle_dir: Path
    bundle: Dict[str, Any]

    @property
    def proof_id(self) -> str:
        return self.bundle["proof_id"]


@dataclass
class ValidationReport:
    status: str
    reasons: List[Dict[str, str]] = field(default_factory=list)
    warnings: List[Dict[str, str]] = field(default_factory=list)
    proof_path: Optional[str] = None

    @property
    def exit_code(self) -> int:
        return {"valid": EXIT_VALID, "incomplete": EXIT_INCOMPLETE, "invalid": EXIT_INVALID}.get(self.status, EXIT_INVALID)

    def as_dict(self) -> Dict[str, Any]:
        return {"status": self.status, "reasons": self.reasons, "warnings": self.warnings}


class BundleValidator:
    """Offline schema, hash, reference, identity, and profile validator."""

    def __init__(self, bundle_path: Union[str, os.PathLike[str]], profile: Optional[Mapping[str, Any]] = None) -> None:
        supplied = Path(bundle_path).expanduser().resolve()
        self.bundle_dir = supplied if supplied.is_dir() else supplied.parent
        self.proof_path = supplied / "proof.json" if supplied.is_dir() else supplied
        self.profile = profile

    def validate(self) -> ValidationReport:
        report = ValidationReport("valid", proof_path=str(self.proof_path))
        try:
            bundle = json.loads(self.proof_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": str(self.proof_path), "detail": f"Cannot parse proof.json: {error}"})
            return report
        schema_result = validate_instance(bundle, load_schema("proof-bundle-v0"))
        report.warnings.extend({"target": issue.path, "detail": issue.message} for issue in schema_result.warnings)
        if not schema_result.is_valid:
            report.status = "invalid"
            report.reasons.extend({"reason": "schema-violation", "target": issue.path, "detail": issue.message} for issue in schema_result.errors)
            return report

        try:
            profile = self.profile or load_profile(bundle.get("profile", {}).get("name", ""))
        except ProofError as error:
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": "profile.name", "detail": str(error)})
            return report

        def profile_violation(target: str, detail: str) -> None:
            report.status = "invalid"
            report.reasons.append(
                {"reason": "profile-violation", "target": target, "detail": detail}
            )

        items = bundle.get("evidence", [])
        secret_scan = profile.get("secret_scan", {}) or {}
        fail_on = list(secret_scan.get("fail_on", []))
        omit_on = set(secret_scan.get("omit_on", []))
        ids: Dict[str, Dict[str, Any]] = {}
        # Compute the expected D4 short IDs before walking references.  A full
        # hash is valid only when two distinct path/hash pairs actually share
        # the same 16-character prefix (the collision extension rule).
        short_groups: Dict[str, set] = {}
        paths_seen: Dict[str, str] = {}
        for item in items:
            pair = (item.get("path"), item.get("sha256"))
            short_groups.setdefault(_evidence_id(str(pair[0]), str(pair[1])), set()).add(pair)
        ac_ids = {criterion.get("id") for criterion in bundle.get("specification", {}).get("acceptance_criteria", [])}
        for item in items:
            identifier = item["id"]
            if identifier in ids:
                report.status = "invalid"
                report.reasons.append({"reason": "duplicate-evidence-id", "target": identifier, "detail": "Evidence IDs must be unique."})
            ids[identifier] = item
            relative = item["path"]
            if relative in paths_seen and paths_seen[relative] != identifier:
                report.status = "invalid"
                report.reasons.append({"reason": "schema-violation", "target": relative, "detail": "Each source evidence path may have only one declaration."})
            paths_seen[relative] = identifier
            digest = item["sha256"]
            expected_short = _evidence_id(relative, digest)
            expected_identifier = (
                _evidence_full_id(relative, digest)
                if len(short_groups.get(expected_short, set())) > 1
                else expected_short
            )
            if identifier != expected_identifier:
                report.status = "invalid"
                report.reasons.append({"reason": "schema-violation", "target": relative, "detail": "Evidence ID does not match the canonical path-plus-hash identity."})
            if not _safe_relative_evidence_path(relative):
                report.status = "invalid"
                report.reasons.append({"reason": "schema-violation", "target": relative, "detail": "Evidence paths must remain relative to evidence/."})
                continue
            if isinstance(item.get("bytes"), bool) or not isinstance(item.get("bytes"), int) or item["bytes"] < 0:
                report.status = "invalid"
                report.reasons.append({"reason": "schema-violation", "target": relative, "detail": "Evidence byte count must be a non-negative integer."})
                continue
            kind = item.get("kind", "unknown")
            status = item["status"]
            omitted_reason = item.get("omitted_reason")
            if status == "included" and omitted_reason is not None:
                profile_violation(
                    relative,
                    "Included evidence must not carry an omission reason.",
                )
            elif status == "omitted":
                if (
                    omitted_reason == "profile-redaction"
                    and not _profile_omits_evidence(relative, kind, profile)
                ):
                    profile_violation(
                        relative,
                        "Evidence is declared profile-redacted without a matching profile rule.",
                    )
                elif (
                    omitted_reason == "absolute-path"
                    and "absolute-path" not in omit_on
                ):
                    profile_violation(
                        relative,
                        "Evidence is declared path-redacted without an active path omission rule.",
                    )
                elif omitted_reason not in {"profile-redaction", "absolute-path"}:
                    profile_violation(
                        relative,
                        "Omitted evidence must use a profile-supported omission reason.",
                    )
            elif status == "truncated" and omitted_reason != "size-limit":
                profile_violation(
                    relative,
                    "Truncated evidence must carry the size-limit omission reason.",
                )
            if (
                status != "omitted"
                and _profile_omits_evidence(relative, kind, profile)
            ):
                profile_violation(
                    relative,
                    "Evidence retained by a profile omission rule.",
                )
            source = self.bundle_dir / "evidence" / relative
            if status == "omitted":
                if source.exists() or source.is_symlink():
                    profile_violation(
                        relative,
                        "Evidence declared omitted must not be present in the Bundle.",
                    )
            elif status == "included":
                if not source.exists() or not source.is_file():
                    report.status = "invalid"
                    report.reasons.append({"reason": "missing-file", "target": relative, "detail": "Declared included evidence file is absent."})
                    continue
                try:
                    data = source.read_bytes()
                except OSError as error:
                    report.status = "invalid"
                    report.reasons.append({"reason": "missing-file", "target": relative, "detail": str(error)})
                    continue
                actual_digest = hashlib.sha256(data).hexdigest()
                if actual_digest != digest or len(data) != item["bytes"]:
                    report.status = "invalid"
                    report.reasons.append({"reason": "hash-mismatch", "target": relative, "detail": "Evidence bytes or declared size differ."})
                if "absolute-path" in omit_on and _has_absolute_path(data):
                    profile_violation(
                        relative,
                        "Included evidence contains an absolute home path that the selected profile requires to be omitted.",
                    )
                else:
                    match = _secret_match(data, fail_on)
                    if match:
                        profile_violation(
                            relative,
                            f"Included evidence matches the profile secret class {match!r}.",
                        )
            elif status == "truncated":
                report.warnings.append({"target": relative, "detail": "Evidence is truncated by its export profile."})

        def require_evidence(identifier: str, target: str) -> None:
            if identifier not in ids:
                report.status = "invalid"
                report.reasons.append({"reason": "dangling-reference", "target": target, "detail": f"Unknown evidence reference {identifier!r}."})

        for finding in bundle.get("findings", []):
            for identifier in finding.get("evidence_refs", []):
                require_evidence(identifier, f"finding:{finding.get('id', '?')}")
            for ac_id in finding.get("ac_refs", []):
                if ac_id not in ac_ids:
                    report.status = "invalid"
                    report.reasons.append({"reason": "dangling-reference", "target": f"finding:{finding.get('id', '?')}", "detail": f"Unknown acceptance criterion reference {ac_id!r}."})
        for row in bundle.get("verdict", {}).get("per_ac", []):
            ac_id = row.get("ac_id")
            if ac_id not in ac_ids:
                report.status = "invalid"
                report.reasons.append({"reason": "dangling-reference", "target": "verdict.per_ac", "detail": f"Unknown acceptance criterion {ac_id!r}."})
            for identifier in list(row.get("supporting", [])) + list(row.get("contradicting", [])):
                require_evidence(identifier, f"verdict:{ac_id}")
        for row in bundle.get("verdict", {}).get("deferred", []):
            if row.get("ac_id") not in ac_ids:
                report.status = "invalid"
                report.reasons.append({"reason": "dangling-reference", "target": "verdict.deferred", "detail": f"Unknown deferred criterion {row.get('ac_id')!r}."})
            require_evidence(row.get("replan_ref", ""), "verdict.deferred")
        for ac_id in bundle.get("verdict", {}).get("required_set", []):
            if ac_id not in ac_ids:
                report.status = "invalid"
                report.reasons.append({"reason": "dangling-reference", "target": "verdict.required_set", "detail": f"Unknown required acceptance criterion {ac_id!r}."})

        expected_id = compute_proof_id(bundle)
        if bundle.get("proof_id") != expected_id:
            report.status = "invalid"
            report.reasons.append({"reason": "proof-id-mismatch", "target": "proof.json", "detail": "proof_id does not match the canonical Bundle payload."})

        expected_profile_hash = _profile_hash(profile)
        if bundle.get("profile", {}).get("schema_hash") != expected_profile_hash:
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": "profile.schema_hash", "detail": "Profile schema_hash does not match the pinned profile document."})
        if bundle.get("profile", {}).get("version") != profile.get("version"):
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": "profile.version", "detail": "Profile version does not match the pinned profile document."})

        expected_omissions = {
            (item["path"], item["omitted_reason"])
            for item in items
            if item.get("status") == "omitted"
        }
        declared_omissions = bundle.get("disclosure", {}).get("omitted", [])
        actual_omissions = {
            (item.get("path"), item.get("reason"))
            for item in declared_omissions
        }
        if (
            len(declared_omissions) != len(actual_omissions)
            or actual_omissions != expected_omissions
        ):
            profile_violation(
                "disclosure.omitted",
                "Disclosure omissions must list each and only each omitted evidence item.",
            )
        expected_redactions = list(profile.get("field_redactions", []))
        if bundle.get("disclosure", {}).get("field_redactions", []) != expected_redactions:
            profile_violation(
                "disclosure.field_redactions",
                "Disclosure field redactions do not match the pinned verification profile.",
            )
        declared_redactions = {
            item.get("field") for item in expected_redactions if isinstance(item, Mapping)
        }
        if "commit.author_email" in declared_redactions:
            for index, record in enumerate(bundle.get("commits", [])):
                if "author_email" in record:
                    profile_violation(
                        f"commits[{index}].author_email",
                        "Commit author email is prohibited by the selected profile.",
                    )
        else:
            for index, record in enumerate(bundle.get("commits", [])):
                if "author_email" not in record:
                    profile_violation(
                        f"commits[{index}].author_email",
                        "Commit author email is required when the selected profile does not redact it.",
                    )
        for index, record in enumerate(bundle.get("commits", [])):
            match = _secret_match(canonical_json_bytes(dict(record)), fail_on)
            if match:
                profile_violation(
                    f"commits[{index}]",
                    f"Commit metadata matches the profile secret class {match!r}.",
                )
        if "absolute-path" in omit_on and _contains_absolute_home_path(bundle):
            profile_violation(
                "proof.json",
                "Bundle contains an absolute home path prohibited by the selected profile.",
            )
        for required_kind in profile.get("required_evidence_kinds", []):
            matching = [
                item
                for item in items
                if item.get("kind") == required_kind
                and item.get("status") == "included"
            ]
            if not matching:
                if report.status == "valid":
                    report.status = "incomplete"
                report.reasons.append({"reason": "profile-required-evidence-missing", "target": required_kind, "detail": f"Required evidence kind {required_kind!r} is absent."})

        for warning in bundle.get("integrity", {}).get("compile_warnings", []):
            report.warnings.append({"target": warning.get("target", ""), "detail": warning.get("detail", ""), "reason": warning.get("reason", "")})
            if warning.get("reason") in {"legacy-version-gap", "unparseable-artifact", "head-commit-unknown", "reviewed-commit-unknown", "truncated-evidence", "profile-required-evidence-missing"} and report.status == "valid":
                report.status = "incomplete"

        def report_has_warning(reason: str) -> bool:
            return any(warning.get("reason") == reason for warning in report.warnings)

        source = bundle.get("source", {})
        for field, reason, detail in (
            (
                "head_commit",
                "head-commit-unknown",
                "Head commit was not recorded by the Run.",
            ),
            (
                "reviewed_commit",
                "reviewed-commit-unknown",
                "Reviewed commit was not recorded by the Run.",
            ),
        ):
            if source.get(field) is None and not report_has_warning(reason):
                report.warnings.append(
                    {"reason": reason, "target": f"source.{field}", "detail": detail}
                )
                if report.status == "valid":
                    report.status = "incomplete"
        reviewed_head_warning = _reviewed_head_warning(
            profile, source.get("head_commit"), source.get("reviewed_commit")
        )
        if reviewed_head_warning is not None and not report_has_warning(
            "reviewed-commit-behind-head"
        ):
            report.warnings.append(reviewed_head_warning)
        published_evidence_bytes = sum(
            item["bytes"] for item in items if item.get("status") == "included"
        )
        size_candidate = _bundle_without_size_budget_warning(bundle)
        size_warning = _size_budget_warning(
            profile, size_candidate, published_evidence_bytes
        )
        if size_warning is not None and not report_has_warning("size-budget-exceeded"):
            report.warnings.append(size_warning)
        return report


def compile_bundle(
    run_dir: Union[str, os.PathLike[str]],
    output_dir: Union[str, os.PathLike[str]],
    profile: str = "public-v0",
    repo_root: Optional[Union[str, os.PathLike[str]]] = None,
) -> Path:
    """Convenience function used by scripts and embedders."""
    bundle, evidence = BundleCompiler(run_dir, profile=profile, repo_root=repo_root).compile()
    return write_bundle(bundle, evidence, _output_outside_run(run_dir, output_dir))


def export_run(
    run_dir: Union[str, os.PathLike[str]],
    output_dir: Optional[Union[str, os.PathLike[str]]] = None,
    profile: str = "public-v0",
    repo_root: Optional[Union[str, os.PathLike[str]]] = None,
) -> ExportResult:
    """Compile and write a Run, using the identity-addressed default if needed."""
    resolved_root = Path(repo_root).resolve() if repo_root else Path.cwd().resolve()
    bundle, evidence = BundleCompiler(run_dir, profile=profile, repo_root=resolved_root).compile()
    destination = Path(output_dir).expanduser() if output_dir else default_output_dir(resolved_root, bundle)
    return ExportResult(
        write_bundle(bundle, evidence, _output_outside_run(run_dir, destination)), bundle
    )


def validate_bundle(bundle_path: Union[str, os.PathLike[str]]) -> ValidationReport:
    """Convenience function used by scripts and tests."""
    return BundleValidator(bundle_path).validate()
