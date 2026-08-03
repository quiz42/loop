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
import os
import platform
import re
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
EXIT_EXPORT_ERROR = 1
EXIT_ACTIVE_RUN = 2
EXIT_SECRET_SCAN = 3
EXIT_UNREADABLE_RUN = 4
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


def _criterion_text(raw: str) -> str:
    """Normalize only list/AC labels; preserve the recorded criterion wording."""
    value = raw.strip()
    value = re.sub(r"^AC[-_ ]?[0-9A-Za-z]+\s*:\s*", "", value, flags=re.IGNORECASE)
    return value.strip()


def _parse_criteria(goal_tracker: Optional[str]) -> Tuple[List[Dict[str, str]], bool]:
    """Parse the immutable acceptance-criteria list and report parse success."""
    if not goal_tracker:
        return [], False
    section = _first_heading_section(goal_tracker, "Acceptance Criteria")
    if section is None:
        return [], False

    criteria: List[Dict[str, str]] = []
    for line in section.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("<!--") or stripped.endswith("-->"):
            continue
        match = re.match(r"^(?:[-*]|[0-9]+[.)])\s+(.*)$", stripped)
        if not match:
            continue
        text = _criterion_text(match.group(1))
        if not text:
            continue
        identifier = f"ac-{len(criteria) + 1}"
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        criteria.append({"id": identifier, "text": text, "text_sha256": digest})
    return criteria, bool(criteria)


def _ac_numbers(raw: str) -> List[int]:
    return [int(value) for value in re.findall(r"AC[-_ ]?([0-9]+)", raw, flags=re.IGNORECASE)]


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


def _parse_completed_and_deferred(goal_tracker: Optional[str]) -> Tuple[set, Dict[int, str], List[Dict[str, str]]]:
    """Return completed AC numbers, evidence text, and explicitly deferred rows."""
    if not goal_tracker:
        return set(), {}, []
    completed_rows = _parse_table_rows(
        _first_heading_section(goal_tracker, "Completed and Verified")
    )
    completed: set = set()
    evidence: Dict[int, str] = {}
    for row in completed_rows:
        if not row or row[0].lower() in ("ac", "acceptance criteria"):
            continue
        numbers = _ac_numbers(row[0])
        if not numbers:
            continue
        completed.update(numbers)
        if len(row) >= 5:
            for number in numbers:
                evidence[number] = row[-1]

    deferred_rows = _parse_table_rows(_first_heading_section(goal_tracker, "Explicitly Deferred"))
    deferred: List[Dict[str, str]] = []
    for row in deferred_rows:
        if not row or row[0].lower() in ("task", "ac"):
            continue
        numbers = _ac_numbers(" ".join(row[:2]))
        if not numbers:
            continue
        # The row's source evidence is the goal tracker itself.  Keep a stable
        # human-readable anchor rather than trying to parse free-form prose.
        for number in numbers:
            deferred.append({"number": str(number), "detail": " | ".join(row)})
    return completed, evidence, deferred


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


_RECOGNIZED_METADATA_PATHS = frozenset({".review-phase-started"})


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
    completed_ac_numbers: set = field(default_factory=set)
    completed_evidence: Dict[int, str] = field(default_factory=dict)
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
        criteria, parsed = _parse_criteria(tracker_text)
        if not parsed:
            warnings.append(
                {
                    "reason": "unparseable-artifact",
                    "target": "goal-tracker.md",
                    "detail": "Acceptance Criteria section was missing or unparseable; no cosmetic criteria were synthesized.",
                }
            )
        goal = ""
        if plan_text:
            goal_section = _first_heading_section(plan_text, "Goal")
            goal = (goal_section or "").strip()
            if not goal:
                first_heading = re.search(r"^#\s+(.+?)\s*$", plan_text, flags=re.MULTILINE)
                goal = first_heading.group(1).strip() if first_heading else ""
        completed, completed_evidence, deferred = _parse_completed_and_deferred(tracker_text)
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
            completed_ac_numbers=completed,
            completed_evidence=completed_evidence,
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


def load_profile(name: str = "local-v0") -> Dict[str, Any]:
    """Load a profile document and fail closed when it is malformed."""
    profile = _default_profile(name)
    result = validate_instance(profile, load_schema("verification-profile-v0"))
    if not result.is_valid:
        detail = "; ".join(f"{issue.path}: {issue.message}" for issue in result.errors)
        raise ProofError(f"invalid verification profile {name!r}: {detail}")
    return profile


def _profile_hash(profile: Mapping[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(canonical_json_bytes(dict(profile))).hexdigest()


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
    return bool(re.search(r"/(?:Users|home)/[^\s/]+", text))


_SECRET_PATTERNS: Tuple[Tuple[str, re.Pattern[str]], ...] = (
    ("pem-header", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("cloud-credential", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9_]{20,}\b")),
    ("token-assignment", re.compile(r"\b(?:token|api[_-]?key|secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9_\-]{8,}", re.IGNORECASE)),
)


def _secret_match(data: bytes, enabled: Sequence[str]) -> Optional[str]:
    if not enabled:
        return None
    text = data.decode("utf-8", errors="replace")
    for kind, pattern in _SECRET_PATTERNS:
        if kind in enabled and pattern.search(text):
            return kind
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
        omit_paths = list(self.profile.get("omit_paths", []))
        omit_kinds = set(self.profile.get("omit_kinds", []))
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
            match = _secret_match(data, fail_on)
            if match:
                raise SecretScanError(relative, match)
            omit_reason: Optional[str] = None
            if kind in omit_kinds or any(fnmatch.fnmatch(relative, pattern) for pattern in omit_paths):
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
            matching = [item for item in items if item["kind"] == required_kind and item["status"] != "omitted"]
            if not matching:
                warnings.append(
                    {
                        "reason": "profile-required-evidence-missing",
                        "target": required_kind,
                        "detail": f"No evidence item of required kind {required_kind!r} was included.",
                    }
                )
        return EvidenceCollection(items, contents, disclosure, warnings)


def _repo_name(repo_root: Optional[Union[str, os.PathLike[str]]], fallback: Path) -> str:
    if repo_root:
        return Path(repo_root).resolve().name
    for candidate in (fallback, *fallback.parents):
        if (candidate / ".git").exists():
            return candidate.name
    return fallback.parent.name


class BundleCompiler:
    """Compile one terminal Run into a schema-valid Proof Bundle mapping."""

    def __init__(
        self,
        run_dir: Union[str, os.PathLike[str]],
        profile: str = "local-v0",
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
        evidence = EvidenceCompiler(run, profile).collect()
        evidence_by_path = {item["path"]: item for item in evidence.items}
        warnings = list(run.warnings) + list(evidence.warnings)
        source = {
            "repo_name": _repo_name(self.repo_root, run.run_dir),
            "base_commit": run.base_commit,
            "head_commit": run.head_commit,
            "reviewed_commit": run.reviewed_commit,
            "loop_version": str(run.state.get("loop_version") or "unknown"),
            "exporter_version": self.exporter_version,
        }
        if run.head_commit is None:
            warnings.append(
                {"reason": "head-commit-unknown", "target": "source.head_commit", "detail": "Head commit was not recorded by the Run."}
            )
        if run.reviewed_commit is None:
            warnings.append(
                {"reason": "reviewed-commit-unknown", "target": "source.reviewed_commit", "detail": "Reviewed commit was not recorded by the Run."}
            )
        elif run.head_commit and run.reviewed_commit != run.head_commit:
            warnings.append(
                {"reason": "reviewed-commit-behind-head", "target": "source.reviewed_commit", "detail": "Reviewed commit differs from the final head commit; badge is withheld."}
            )

        def evidence_refs_for_path(path: str) -> List[str]:
            item = evidence_by_path.get(path)
            return [item["id"]] if item else []

        tracker_ref = evidence_refs_for_path("goal-tracker.md")
        review_refs = [item["id"] for item in evidence.items if item["kind"] == "round_review_result"]
        summary_refs = [item["id"] for item in evidence.items if item["kind"] == "round_summary"]
        per_ac: List[Dict[str, Any]] = []
        deferred_output: List[Dict[str, str]] = []
        deferred_numbers = {int(item["number"]) for item in run.deferred}
        for criterion in run.acceptance_criteria:
            number = int(criterion["id"].split("-")[-1])
            supporting = tracker_ref + review_refs + summary_refs if number in run.completed_ac_numbers else []
            status = "met" if number in run.completed_ac_numbers else (
                "unmet" if run.terminal_state != "complete" else "unverifiable"
            )
            reason = "Recorded in the Completed and Verified table." if status == "met" else (
                "Run ended before this criterion was recorded as completed." if status == "unmet" else "No structured completion record was found."
            )
            if number in deferred_numbers:
                status = "deferred"
                reason = "Criterion was explicitly deferred in the Goal Tracker."
                deferred_output.append({"ac_id": criterion["id"], "replan_ref": tracker_ref[0] if tracker_ref else "goal-tracker.md"})
            per_ac.append(
                {
                    "ac_id": criterion["id"],
                    "status": status,
                    "reason": reason,
                    "supporting": supporting,
                    "contradicting": [],
                }
            )

        required_set = [criterion["id"] for criterion in run.acceptance_criteria if criterion["id"] not in {item["ac_id"] for item in deferred_output}]
        required_statuses = [item["status"] for item in per_ac if item["ac_id"] in required_set]
        if not required_statuses:
            decision = "unverifiable"
        elif all(status == "met" for status in required_statuses):
            decision = "accept"
        elif any(status == "unmet" for status in required_statuses):
            decision = "changes_required"
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
            "specification": {"goal": run.goal, "acceptance_criteria": run.acceptance_criteria},
            "run": {
                "session_timestamp": run.session_timestamp,
                "terminal_state": run.terminal_state,
                "rounds": run.rounds,
                "events": run.events,
            },
            "evidence": evidence.items,
            "findings": [],
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
        bundle["proof_id"] = compute_proof_id(bundle)
        schema_result = validate_instance(bundle, load_schema("proof-bundle-v0"))
        if not schema_result.is_valid:
            detail = "; ".join(f"{issue.path}: {issue.message}" for issue in schema_result.errors)
            raise ProofError(f"compiler produced an invalid Proof Bundle: {detail}")
        return bundle, evidence


def write_bundle(
    bundle: Mapping[str, Any],
    evidence: EvidenceCollection,
    output_dir: Union[str, os.PathLike[str]],
) -> Path:
    """Write canonical ``proof.json`` and included raw evidence safely."""
    target = Path(output_dir).expanduser().resolve()
    try:
        target.mkdir(parents=True, exist_ok=True)
        proof_path = target / "proof.json"
        proof_path.write_text(
            json.dumps(bundle, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        (target / "proof-data.js").write_text(
            "window.PROOF = "
            + json.dumps(bundle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            + ";\n",
            encoding="utf-8",
        )
        for relative, content in evidence.contents.items():
            destination = target / "evidence" / relative
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

        items = bundle.get("evidence", [])
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
            source = self.bundle_dir / "evidence" / relative
            if item["status"] == "included":
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
            elif item["status"] == "truncated":
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

        try:
            profile = self.profile or load_profile(bundle.get("profile", {}).get("name", ""))
        except ProofError as error:
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": "profile.name", "detail": str(error)})
            return report
        expected_profile_hash = _profile_hash(profile)
        if bundle.get("profile", {}).get("schema_hash") != expected_profile_hash:
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": "profile.schema_hash", "detail": "Profile schema_hash does not match the pinned profile document."})
        if bundle.get("profile", {}).get("version") != profile.get("version"):
            report.status = "invalid"
            report.reasons.append({"reason": "schema-violation", "target": "profile.version", "detail": "Profile version does not match the pinned profile document."})
        for required_kind in profile.get("required_evidence_kinds", []):
            matching = [item for item in items if item.get("kind") == required_kind and item.get("status") in ("included", "truncated")]
            if not matching:
                if report.status == "valid":
                    report.status = "incomplete"
                report.reasons.append({"reason": "profile-required-evidence-missing", "target": required_kind, "detail": f"Required evidence kind {required_kind!r} is absent."})

        for warning in bundle.get("integrity", {}).get("compile_warnings", []):
            report.warnings.append({"target": warning.get("target", ""), "detail": warning.get("detail", ""), "reason": warning.get("reason", "")})
            if warning.get("reason") in {"legacy-version-gap", "unparseable-artifact", "head-commit-unknown", "reviewed-commit-unknown", "truncated-evidence", "profile-required-evidence-missing"} and report.status == "valid":
                report.status = "incomplete"
        return report


def compile_bundle(
    run_dir: Union[str, os.PathLike[str]],
    output_dir: Union[str, os.PathLike[str]],
    profile: str = "local-v0",
    repo_root: Optional[Union[str, os.PathLike[str]]] = None,
) -> Path:
    """Convenience function used by scripts and embedders."""
    bundle, evidence = BundleCompiler(run_dir, profile=profile, repo_root=repo_root).compile()
    return write_bundle(bundle, evidence, _output_outside_run(run_dir, output_dir))


def export_run(
    run_dir: Union[str, os.PathLike[str]],
    output_dir: Optional[Union[str, os.PathLike[str]]] = None,
    profile: str = "local-v0",
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
