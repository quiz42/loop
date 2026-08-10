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

_INTEGRITY_INVALID_REASONS = frozenset(
    (
        "schema-violation",
        "hash-mismatch",
        "proof-id-mismatch",
        "dangling-reference",
        "duplicate-evidence-id",
        "integrity-status-mismatch",
    )
)
_INTEGRITY_INCOMPLETE_REASONS = frozenset(
    (
        "missing-file",
        "profile-required-evidence-missing",
        "legacy-version-gap",
        "unparseable-artifact",
        "truncated-evidence",
        "head-commit-unknown",
        "reviewed-commit-unknown",
    )
)
_INTEGRITY_STATUS_MISMATCH_REASON = "integrity-status-mismatch"


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


def _integrity_status(warnings: Iterable[Mapping[str, Any]]) -> str:
    """Project compiler facts into the three public integrity states.

    The static Explorer cannot read raw files over ``file://`` to run the
    validator itself.  Export therefore records the compiler's conservative
    integrity projection in the canonical manifest, while ``proof verify``
    remains the authority for validation after the Bundle is copied.
    """
    reasons = {
        warning.get("reason")
        for warning in warnings
        if isinstance(warning, Mapping) and isinstance(warning.get("reason"), str)
    }
    if reasons.intersection(_INTEGRITY_INVALID_REASONS):
        return "invalid"
    if reasons.intersection(_INTEGRITY_INCOMPLETE_REASONS):
        return "incomplete"
    return "valid"


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


def _decode_text(data: Optional[bytes]) -> Optional[str]:
    """Decode published Bundle bytes, or None when there are none to read."""
    if data is None:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
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
# The boundary every reference form must stop at. Shared between the single
# and the range pattern so the range grammar can never be narrower than the
# single-reference grammar: `AC1-AC5:` in a table cell ends exactly as `AC5:`
# does. A sentence-final period is deliberately not a boundary in either
# grammar -- `AC5.` and `AC1-AC5.` are both reported as malformed rather than
# read -- so widening to prose-style references is a grammar decision, not a
# missing case.
_AC_BOUNDARY = r"(?=(?:\s|[,;|)]|$|:\s|:$))"
_AC_REFERENCE = re.compile(r"\bAC-?([0-9]+)" + _AC_BOUNDARY, re.IGNORECASE)
_AC_REFERENCE_ATTEMPT = re.compile(
    r"(?<![A-Za-z0-9_])AC(?:[-_ ]?[^\s,;|)]*|[-_])",
    re.IGNORECASE,
)
# An inclusive range over criterion labels: `AC1-AC5` and its `AC1-5` short
# form, both of which a real Goal Tracker writes. Anchored on both ends so a
# hyphenated word is not mistaken for one.
_AC_RANGE = re.compile(
    r"(?<![A-Za-z0-9_])AC-?([0-9]+)\s*-\s*(?:AC-?)?([0-9]+)" + _AC_BOUNDARY,
    re.IGNORECASE,
)
# A range wider than this is a typo, not a reference to that many criteria.
_AC_RANGE_MAX_SPAN = 63
# A criterion number or round ordinal longer than this is not a number a
# tracker wrote. CPython additionally refuses int() past 4,300 digits, so an
# unbounded token would abort the whole export with a conversion error
# instead of producing a Bundle that reports what it could not read.
_NUMERIC_TOKEN_MAX_DIGITS = 9


def _bounded_int(digits: str) -> Optional[int]:
    """Convert a digit token a tracker plausibly wrote, or return None."""
    normalized = digits.lstrip("0") or "0"
    if len(normalized) > _NUMERIC_TOKEN_MAX_DIGITS:
        return None
    try:
        return int(normalized)
    except ValueError:
        return None


def _reference_token(token: str) -> str:
    """Shorten a reported reference token so one absurd cell cannot bloat
    every warning that quotes it."""
    return token if len(token) <= 120 else token[:117] + "..."


def _ac_id(number: str) -> str:
    """Normalize an AC number into the stable identifier used in a Bundle."""
    return f"ac-{number.lstrip('0') or '0'}"


def _looks_like_malformed_ac_label(raw: str) -> bool:
    """Recognize an attempted AC label that is not in the v0 label form."""
    return bool(
        re.match(r"^AC(?:[0-9_-].*| [^:]*|)?\s*:", raw, flags=re.IGNORECASE)
        or re.match(r"^AC(?:[0-9]|[-_][0-9])(?:\s|$)", raw, flags=re.IGNORECASE)
    )


_CRITERION_BULLET = re.compile(r"^(?:[-*+]|[0-9]+[.)])\s+(.*)$")
# Markdown block structure a criterion never continues across. A heading, a
# thematic break, a table row, or a fence is layout, not more criterion text.
_NESTED_HEADING = re.compile(r"^#{1,6}(?:\s|$)")
_THEMATIC_BREAK = re.compile(r"^([-_*])(?:\s*\1){2,}\s*$")
_CODE_FENCE = re.compile(r"^(?:`{3,}|~{3,})")
# A setext H1 underline: the line above it is a heading, never criterion
# text. `-` underlines are deliberately not read this way -- a real tracker
# writes `---` as a separator, and reading it as an underline would eat the
# last wrapped line of the criterion above it. Reading `=` lines as
# underlines is itself a deliberate divergence from CommonMark, whose
# lazy-continuation rule would fold both the heading text and the `=` line
# into the criterion's paragraph -- exactly the absorption into attested
# text this reader exists to prevent.
_SETEXT_UNDERLINE = re.compile(r"^={3,}\s*$")
# The HTML block tags that can interrupt a paragraph (CommonMark type 6).
# A generic tag (type 7) cannot, so inline HTML at the start of a wrapped
# continuation line still folds.
_HTML_BLOCK_TAG = re.compile(
    r"^</?(?:address|article|aside|base|basefont|blockquote|body|caption"
    r"|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset"
    r"|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head"
    r"|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav"
    r"|noframes|ol|optgroup|option|p|param|search|section|summary|table"
    r"|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\s|/?>|$)",
    re.IGNORECASE,
)


def _criteria_list_items(section: str) -> List[str]:
    """Return each Acceptance Criteria list item as one whole criterion.

    A criterion wraps. Real plans hard-wrap at the margin, so the tracker's
    IMMUTABLE section routinely holds

        - AC1: `parse(version)` accepts a valid SemVer 2.0.0 string and
          returns a structure exposing major, minor and patch.

    Reading only the bullet line recorded "...string and" as the criterion and
    dropped the rest, silently: the continuation lines match no bullet, so they
    were skipped rather than reported. The Acceptance Matrix then showed the
    maintainer a criterion cut off mid-sentence, and `text_sha256` committed to
    the fragment. Continuation lines are folded back in, joined with a single
    space; a blank line ends the item.

    Only prose continues an item. Markdown block structure -- a nested
    heading, a thematic break, a table row, a code fence, an HTML comment, a
    block quote, or a nested list bullet -- ends the item where it stands and is never folded
    into the criterion the Acceptance Matrix attests to; prose after such a
    block is commentary on the list, not part of any item. Continuation prose
    is deliberately not required to be indented: a flush-left hard wrap is
    exactly the shape this reader exists to keep, and dropping it because of
    its indentation would silently re-truncate the criterion.
    """
    items: List[str] = []
    current: Optional[List[str]] = None
    base_indent: Optional[int] = None
    in_comment = False
    in_fence = False

    def flush() -> None:
        if current is not None:
            items.append(" ".join(part for part in current if part))

    for line in section.splitlines():
        stripped = line.strip()
        if in_comment:
            if "-->" in stripped:
                in_comment = False
            continue
        if in_fence:
            if _CODE_FENCE.match(stripped):
                in_fence = False
            continue
        if not stripped:
            flush()
            current = None
            continue
        if stripped.startswith("<!--"):
            flush()
            current = None
            if "-->" not in stripped:
                in_comment = True
            continue
        if _CODE_FENCE.match(stripped):
            flush()
            current = None
            in_fence = True
            continue
        if _SETEXT_UNDERLINE.match(stripped):
            # The underline promotes the line above it into a heading, so
            # that line was never criterion text: unfold it before flushing.
            if current is not None and len(current) > 1:
                current.pop()
            flush()
            current = None
            continue
        if (
            _NESTED_HEADING.match(stripped)
            or _THEMATIC_BREAK.match(stripped)
            or stripped.startswith("|")
            # Block quotes and type-6 HTML blocks can interrupt a paragraph
            # (CommonMark), so neither is ever lazy continuation of the
            # criterion above it.
            or stripped.startswith(">")
            or _HTML_BLOCK_TAG.match(stripped)
        ):
            flush()
            current = None
            continue
        match = _CRITERION_BULLET.match(stripped)
        if match:
            indent = len(line) - len(line.lstrip())
            if base_indent is None:
                base_indent = indent
            if indent > base_indent:
                # A nested list belongs to the criterion above it the way a
                # table does: structure, not a criterion and not more text.
                flush()
                current = None
                continue
            flush()
            current = [match.group(1).strip()]
        elif current is not None:
            current.append(stripped)
    flush()
    return items


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
    for raw in _criteria_list_items(section):
        list_position += 1
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


def _expand_ac_ranges(raw: str) -> Tuple[List[str], str, List[str]]:
    """Return the IDs the AC ranges name, the text without any range, and the
    range-shaped tokens that name no readable criteria.

    A Goal Tracker row that covers several criteria at once is written as a
    range: four of the nine M4 dogfood Runs put `AC1-AC5` in the Completed and
    Verified table. That form matched neither the single-reference pattern nor
    the well-formed shape, so the row resolved to its last criterion alone and
    reported the rest as a malformed reference -- and since a malformed
    reference invalidates the AC mapping, one range cost the whole delivery its
    verdict while three or four genuinely verified criteria fell back to
    `unverifiable`.

    A range is a label form, not prose: `AC1-AC5` states which criteria it
    names as exactly as `AC1, AC2, AC3, AC4, AC5` does, so reading it stays
    inside ADR-0002. A range that is shaped like one but names no readable
    criteria -- descending, absurdly wide, or with an endpoint no tracker
    would number -- is consumed whole and reported malformed: leaving it in
    the remainder let the single-reference scan accept one endpoint of a
    reference this reader had already rejected.
    """
    identifiers: List[str] = []
    malformed: List[str] = []
    remainder: List[str] = []
    last = 0
    for match in _AC_RANGE.finditer(raw):
        remainder.append(raw[last : match.start()])
        last = match.end()
        first_number = _bounded_int(match.group(1))
        last_number = _bounded_int(match.group(2))
        if (
            first_number is None
            or last_number is None
            or last_number < first_number
            or last_number - first_number > _AC_RANGE_MAX_SPAN
        ):
            token = _reference_token(match.group(0))
            if token not in malformed:
                malformed.append(token)
            continue
        for number in range(first_number, last_number + 1):
            identifier = _ac_id(str(number))
            if identifier not in identifiers:
                identifiers.append(identifier)
    remainder.append(raw[last:])
    return identifiers, " ".join(remainder), malformed


def _ac_ids_and_remainder(raw: str) -> Tuple[List[str], str, List[str]]:
    """Return the criterion IDs the text names, the text no range explained,
    and the range-shaped tokens that are not valid references.

    Ranges are consumed first -- valid or not -- so the malformed-reference
    scan never sees a range and the single-reference scan never reads an
    endpoint out of one; what they do see is everything a range did not
    claim.
    """
    identifiers, remainder, malformed = _expand_ac_ranges(raw)
    for match in _AC_REFERENCE.finditer(remainder):
        identifier = _ac_id(match.group(1))
        if identifier not in identifiers:
            identifiers.append(identifier)
    return identifiers, remainder, malformed


def _ac_ids(raw: str) -> List[str]:
    """Return stable criterion IDs explicitly named in free-form table text."""
    return _ac_ids_and_remainder(raw)[0]


def _ac_references(raw: str) -> Tuple[List[str], List[str]]:
    """Return valid AC IDs and any malformed AC-like references in the text."""
    identifiers, remainder, malformed_ranges = _ac_ids_and_remainder(raw)
    malformed: List[str] = list(malformed_ranges)
    for match in _AC_REFERENCE_ATTEMPT.finditer(remainder):
        token = match.group(0)
        if not re.fullmatch(r"AC-?[0-9]+(?::)?", token, flags=re.IGNORECASE):
            token = _reference_token(token)
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


def _plan_evolution_events(goal_tracker: Optional[str]) -> List[Dict[str, Any]]:
    """Project Goal Tracker plan-evolution rows into safe timeline facts.

    The Explorer is intentionally prohibited from parsing Markdown.  This
    adapter-side projection retains the round without copying free-form tracker
    prose (which may be redacted by a public profile).  A Plan Evolution row
    alone is not enough to infer that a replan occurred.
    """
    rows = _parse_table_rows(
        _first_heading_section(goal_tracker or "", "Plan Evolution Log")
    )
    if not rows:
        return []
    header = [cell.strip().lower() for cell in rows[0]]
    if "round" not in header:
        return []
    round_column = header.index("round")
    events: List[Dict[str, Any]] = []
    for row in rows[1:]:
        if round_column >= len(row):
            continue
        match = re.fullmatch(r"(?:round\s+)?([0-9]+)", row[round_column], re.IGNORECASE)
        if match is None:
            continue
        round_number = _bounded_int(match.group(1))
        if round_number is None:
            continue
        events.append({"kind": "plan_evolution", "at": None, "round": round_number})
    return events


def _round_value(raw: str) -> Optional[int]:
    """Return a round ordinal from a table cell, or None when it is not one.

    A tracker writes "0", "Round 0", and also "pending" or "-" while the work is
    still in flight. Only the first form is a recorded round.
    """
    match = re.fullmatch(r"(?:round\s+)?([0-9]+)", raw.strip(), re.IGNORECASE)
    return _bounded_int(match.group(1)) if match else None


def _parse_completed_and_deferred(
    goal_tracker: Optional[str], known_ac_ids: Sequence[str]
) -> Tuple[Dict[str, int], set, List[Dict[str, Any]], List[str]]:
    """Resolve completed/deferred table references against known stable AC IDs.

    Returns the verified completions, the completions recorded without a
    Verified Round, the deferrals, and any table problems.
    """
    if not goal_tracker:
        return {}, set(), [], []
    known = set(known_ac_ids)
    problems: List[str] = []
    completed_rows = _parse_table_rows(
        _first_heading_section(goal_tracker, "Completed and Verified")
    )
    # Spec section G: an AC is `met` only when its Completed and Verified row
    # carries a Verified Round. The column was previously not read at all, so a
    # row still reading "pending" -- the literal value the tracker template
    # writes while a round is awaiting review -- produced `met` and `accept`.
    verified_column: Optional[int] = None
    if completed_rows:
        header = [cell.strip().lower() for cell in completed_rows[0]]
        if "verified round" in header:
            verified_column = header.index("verified round")
    completed: Dict[str, int] = {}
    completed_unverified: set = set()
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
        # No Verified Round column at all is treated the same as an unfilled
        # one: the tracker did not record the verification this status needs.
        verified_round = None
        if verified_column is not None and verified_column < len(row):
            verified_round = _round_value(row[verified_column])
        for identifier in identifiers:
            if identifier not in known:
                continue
            if verified_round is None:
                completed_unverified.add(identifier)
            else:
                # The round number is carried out so the verdict can check it
                # against the rounds the Run actually recorded. A syntactically
                # valid "999" is not a verification that happened.
                completed[identifier] = verified_round

    deferred_rows = _parse_table_rows(_first_heading_section(goal_tracker, "Explicitly Deferred"))
    deferred: List[Dict[str, str]] = []
    # "Deferred Since" names the round the deferral happened in. It is captured
    # so the verdict can require a matching Plan Evolution Log row before
    # accepting the deferral: a row that cites no round cites no replan.
    since_column: Optional[int] = None
    # Only the Original AC column names what was deferred. Reading the Task
    # prose as well meant a row whose task text happened to mention another
    # criterion ("Defer AC4 work as well") silently dropped that criterion from
    # the required set too.
    original_ac_column: Optional[int] = None
    if deferred_rows:
        header = [cell.strip().lower() for cell in deferred_rows[0]]
        if "deferred since" in header:
            since_column = header.index("deferred since")
        for candidate in ("original ac", "ac"):
            if candidate in header:
                original_ac_column = header.index(candidate)
                break
    for row in deferred_rows:
        if not row or row[0].lower() in ("task", "ac"):
            continue
        if original_ac_column is None:
            # No labelled Original AC column. Guessing at cell 2 read whatever
            # happened to sit there -- renaming the column to "Owner" and
            # putting AC5 in it silently shrank the required set. A table this
            # deriver cannot read is a table problem, which makes the mapping
            # invalid and the verdict unverifiable, not a licence to guess.
            problems.append(
                "Explicitly Deferred has no Original AC column, so its "
                "deferrals cannot be resolved to acceptance criteria."
            )
            continue
        if original_ac_column >= len(row):
            continue
        identifiers, malformed = _ac_references(row[original_ac_column])
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
        since_round: Optional[int] = None
        if since_column is not None and since_column < len(row):
            since_round = _round_value(row[since_column])
        # The row's source evidence is the goal tracker itself.  Keep a stable
        # human-readable anchor rather than trying to parse free-form prose.
        for identifier in identifiers:
            if identifier in known:
                entry: Dict[str, Any] = {
                    "ac_id": identifier,
                    "detail": " | ".join(row),
                }
                if since_round is not None:
                    entry["since_round"] = since_round
                deferred.append(entry)
    return completed, completed_unverified, deferred, problems


def _replan_ac_rounds(goal_tracker: Optional[str]) -> set:
    """Return (ac_id, round) pairs the Plan Evolution Log records a replan for.

    Matching a deferral on the round alone is not enough: every Run opens with
    a "| 0 | Initial plan |" row, so any deferral citing round 0 would be
    authorized by a row that replanned nothing. The row has to name the
    criterion.

    Only the declared "Impact on AC" column is read. Scanning every cell meant
    an incidental token in a Change or Reason cell -- "Reworded notes
    mentioning AC5" -- authorized deferring AC5, which is the prose reading
    ADR-0002 rules out. A log without that column authorizes no deferral.
    """
    rows = _parse_table_rows(
        _first_heading_section(goal_tracker or "", "Plan Evolution Log")
    )
    if not rows:
        return set()
    header = [cell.strip().lower() for cell in rows[0]]
    if "round" not in header or "impact on ac" not in header:
        return set()
    round_column = header.index("round")
    impact_column = header.index("impact on ac")
    pairs = set()
    for row in rows[1:]:
        if round_column >= len(row) or impact_column >= len(row):
            continue
        round_index = _round_value(row[round_column])
        if round_index is None:
            continue
        for identifier in _ac_ids(row[impact_column]):
            pairs.add((identifier, round_index))
    return pairs


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


# The marker Loop writes when a Run leaves implementation. Its `build_finish_round`
# is the only Run fact that separates the rounds which had to deliver work from
# the rounds that only reviewed it, so it is named once and read everywhere.
REVIEW_PHASE_MARKER = ".review-phase-started"

_RECOGNIZED_METADATA_PATHS = frozenset({".cancel-requested", REVIEW_PHASE_MARKER})


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
    # Maps a criterion to the round its Completed and Verified row recorded as
    # the Verified Round.
    completed_ac_ids: Dict[str, int] = field(default_factory=dict)
    # Recorded in Completed and Verified but without a Verified Round, so
    # completion is claimed and verification is not evidenced.
    unverified_completion_ac_ids: set = field(default_factory=set)
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
        completed, completed_unverified, deferred, table_problems = _parse_completed_and_deferred(
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
        rounds, events = self._rounds_and_events(
            _timestamp_or_none(state.get("ended_at")), state, tracker_text
        )
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
            unverified_completion_ac_ids=completed_unverified,
            deferred=deferred,
            warnings=warnings,
            rounds=rounds,
            events=events,
        )

    @staticmethod
    def _has_any_state_fact(state: Mapping[str, Any], names: Sequence[str]) -> bool:
        return any(state.get(name) not in (None, "") for name in names)

    def _rounds_and_events(
        self,
        ended_at: Optional[str],
        state: Mapping[str, Any],
        goal_tracker: Optional[str],
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        """Record only structured Run facts needed by the offline timeline."""
        indexes = set()
        completed_artifact = re.compile(
            r"round-([0-9]+)-(?:contract|summary|review-result)\.md$"
        )
        for path in self.run_dir.iterdir() if self.run_dir.exists() else []:
            match = completed_artifact.match(path.name)
            if match:
                indexes.add(int(match.group(1)))
        rounds = [{"index": index} for index in sorted(indexes)]
        plan_events = _plan_evolution_events(goal_tracker)
        plan_events_by_round: Dict[int, List[Dict[str, Any]]] = {}
        for event in plan_events:
            # _plan_evolution_events emits only integer rounds, so every
            # projected event has a deterministic position in this timeline.
            plan_events_by_round.setdefault(event["round"], []).append(event)
        events: List[Dict[str, Any]] = [{"kind": "setup", "at": None}]
        for index in sorted(indexes):
            events.append({"kind": "round", "at": None, "round": index})
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
                            "round": index,
                            "verdict": verdict.group(1).lower(),
                        }
                    )
            events.extend(plan_events_by_round.pop(index, []))
        for round_index in sorted(plan_events_by_round):
            events.extend(plan_events_by_round[round_index])
        drift_status = state.get("drift_status")
        if drift_status == "replan_required":
            stall_count = state.get("mainline_stall_count")
            circuit_breaker: Dict[str, Any] = {
                "kind": "circuit_breaker",
                "at": None,
                "drift_status": drift_status,
                "detail": "Mainline drift required a replan before the Run ended.",
            }
            if isinstance(stall_count, int) and not isinstance(stall_count, bool):
                circuit_breaker["stall_count"] = stall_count
            last_verdict = state.get("last_mainline_verdict")
            if isinstance(last_verdict, str):
                normalized_verdict = last_verdict.lower()
                if normalized_verdict in {
                    "advanced",
                    "stalled",
                    "regressed",
                    "unknown",
                }:
                    circuit_breaker["last_mainline_verdict"] = normalized_verdict
            events.append(circuit_breaker)
        if (self.run_dir / ".review-phase-started").exists():
            events.append({"kind": "review_phase", "at": None})
        if (self.run_dir / "finalize-summary.md").exists():
            events.append({"kind": "finalize", "at": None})
        events.append({"kind": "terminal", "at": ended_at})
        return rounds, events


# The profile export uses when none is named. Every library entry point and
# the CLI read this one name, so a future profile revision -- which ADR-0006
# makes a rename -- cannot leave the defaults out of sync with each other.
DEFAULT_EXPORT_PROFILE = "public-v1"


def _default_profile(name: str) -> Dict[str, Any]:
    if re.fullmatch(r"[a-z][a-z0-9-]*-v[0-9]+", name):
        path = Path(__file__).resolve().parent / "profiles" / f"{name}.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    raise ProofError(f"unknown verification profile {name!r}")


def load_profile(name: str = DEFAULT_EXPORT_PROFILE) -> Dict[str, Any]:
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


_EXPLORER_ASSET_NAMES = ("index.html", "app.js", "styles.css")


def _explorer_asset_bytes() -> Dict[str, bytes]:
    """Load the static, dependency-free Explorer files shipped with Loop."""
    source_dir = Path(__file__).resolve().parent / "explorer"
    assets: Dict[str, bytes] = {}
    try:
        for name in _EXPLORER_ASSET_NAMES:
            contents = (source_dir / name).read_bytes()
            if not contents:
                raise BundleWriteError(f"Proof Explorer asset is empty: {name}")
            assets[name] = contents
    except OSError as error:
        raise BundleWriteError(
            f"cannot read bundled Proof Explorer assets from {source_dir}: {error}"
        ) from error
    return assets


def _explorer_asset_hashes(assets: Mapping[str, bytes]) -> Dict[str, str]:
    """Return the canonical renderer attestations for the packaged assets."""
    return {
        name: "sha256:" + hashlib.sha256(assets[name]).hexdigest()
        for name in _EXPLORER_ASSET_NAMES
    }


def _declared_explorer_asset_hashes(bundle: Mapping[str, Any]) -> Dict[str, str]:
    """Require complete renderer attestations before writing a new Bundle."""
    explorer = bundle.get("explorer")
    assets = explorer.get("assets") if isinstance(explorer, Mapping) else None
    if not isinstance(assets, Mapping):
        raise BundleWriteError(
            "Proof Bundle must declare explorer.assets for its packaged Explorer."
        )
    declared: Dict[str, str] = {}
    for name in _EXPLORER_ASSET_NAMES:
        digest = assets.get(name)
        if not isinstance(digest, str):
            raise BundleWriteError(
                f"Proof Bundle explorer.assets is missing an attestation for {name}."
            )
        declared[name] = digest
    return declared


def _deterministic_managed_bundle_bytes(
    bundle: Mapping[str, Any], published_evidence_bytes: int, explorer_bytes: Optional[int] = None
) -> int:
    """Measure generated Bundle files without mutable transport metadata."""
    projection = dict(bundle)
    projection.pop("transport", None)
    proof_json, proof_data = _bundle_document_bytes(projection)
    if explorer_bytes is None:
        explorer_bytes = sum(len(contents) for contents in _explorer_asset_bytes().values())
    return len(proof_json) + len(proof_data) + explorer_bytes + published_evidence_bytes


def _size_budget_warning(
    profile: Mapping[str, Any],
    bundle: Mapping[str, Any],
    published_evidence_bytes: int,
    explorer_bytes: Optional[int] = None,
) -> Optional[Dict[str, str]]:
    """Return a stable size warning from the pre-warning managed output.

    The rendered manifests count toward the bundle budget, while transport does
    not: it is outside Proof identity and would make this canonical warning vary
    by host or export time.
    """
    max_bundle_bytes = profile.get("max_bundle_bytes")
    managed_bundle_bytes = _deterministic_managed_bundle_bytes(
        bundle, published_evidence_bytes, explorer_bytes
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


# The one definition of "absolute home path". The scanner and the mask below
# must never disagree about what they are looking at: a mask that cleaned less
# than the scan detects would publish the very thing the scan exists to catch.
_ABSOLUTE_HOME_PATH = re.compile(r"(?<![A-Za-z0-9._-])/(?:Users|home)/[^\s/]+")
# What a masked item shows instead. Deliberately not a path, so a reader cannot
# mistake it for one, and fixed, so masking is deterministic.
MASKED_HOME_PLACEHOLDER = "<masked-home>"


def _has_absolute_path(data: bytes) -> bool:
    text = data.decode("utf-8", errors="replace")
    return bool(_ABSOLUTE_HOME_PATH.search(text))


def mask_absolute_paths(data: bytes) -> Optional[bytes]:
    """Return the bytes a profile may publish in place of path-bearing ones.

    Returns None when the item cannot be masked and must be withheld instead:
    bytes that are not UTF-8 cannot be rewritten without corrupting them, and a
    substitution that somehow leaves a match behind must not be published.
    Shared by the compiler, which produces these bytes, and the validator,
    which re-derives the rule to check a `masked` declaration against the
    profile that claims to have produced it.
    """
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    masked = _ABSOLUTE_HOME_PATH.sub(MASKED_HOME_PLACEHOLDER, text).encode("utf-8")
    return None if _has_absolute_path(masked) else masked


def _evidence_is_published(item: Optional[Mapping[str, Any]]) -> bool:
    """Return whether the Bundle carries readable bytes for this item.

    `included` and `masked` are both published; `omitted` and `truncated` are
    not. Every "can this Bundle show its reader the source?" question routes
    here, because answering it in each caller is how a masked item would end up
    trusted in one place and ignored in another.
    """
    return bool(item) and item.get("status") in ("included", "masked")


def _published_digest(item: Mapping[str, Any]) -> Optional[str]:
    """Return the hash of the bytes this Bundle actually carries for an item."""
    if item.get("status") == "masked":
        digest = item.get("masked_sha256")
        return digest if isinstance(digest, str) else None
    digest = item.get("sha256")
    return digest if isinstance(digest, str) else None


def _published_byte_count(item: Mapping[str, Any]) -> Optional[int]:
    """Return the size of the bytes this Bundle actually carries for an item."""
    key = "masked_bytes" if item.get("status") == "masked" else "bytes"
    value = item.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


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


def profile_masks_kind(kind: str, scan_class: str, profile: Mapping[str, Any]) -> bool:
    """Return whether a profile publishes this kind masked for this scan class.

    Both halves are required, and the kind half is the narrow one. A masked
    item's bytes differ from its source, so anything the Compiler projects out
    of that source into `proof.json` would then be asserting facts the Bundle
    cannot show. Review results project only findings, which the Compiler reads
    from the published bytes; the Goal Tracker, plan and state artifacts
    project criterion text, deferral rows and frontmatter, so v0's profile
    schema does not let them be masked at all.
    """
    secret_scan = profile.get("secret_scan", {}) or {}
    return scan_class in set(secret_scan.get("mask_on", [])) and kind in set(
        secret_scan.get("mask_kinds", [])
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
    # Masked items are published, not withheld, so they are declared separately
    # from `disclosure`: a reader scanning the omission list must not have to
    # tell "you cannot see this" apart from "you can see this, altered".
    masked: List[Dict[str, str]] = field(default_factory=list)


class EvidenceCompiler:
    """Collect raw-byte evidence and create profile declarations."""

    def __init__(self, run: RunRecord, profile: Mapping[str, Any]) -> None:
        self.run = run
        self.profile = profile

    def collect(self) -> EvidenceCollection:
        items: List[Dict[str, Any]] = []
        contents: Dict[str, bytes] = {}
        disclosure: List[Dict[str, str]] = []
        masked: List[Dict[str, str]] = []
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
            masked_data: Optional[bytes] = None
            # Size is a property of the source evidence, not of what masking
            # leaves of it. Deciding it after substitution let one long
            # masked-out path publish an item under public-v1 that local-v0
            # truncates, so the thinner profile carried the more complete
            # Bundle -- and no local Bundle held the source bytes that could
            # corroborate the masking (ADR-0004's trust boundary).
            oversized = len(data) > max_item_bytes
            if _profile_omits_evidence(relative, kind, self.profile):
                omit_reason = "profile-redaction"
            elif _has_absolute_path(data):
                # Masking is tried first because withholding this item costs
                # more than altering it: in the M4 dogfood every review result
                # that reported a finding cited the faulted file by absolute
                # path, so the omission rule withheld exactly the evidence a
                # maintainer most needs. Only kinds the profile names may be
                # masked, and only when the substitution actually cleans the
                # bytes; anything else falls through to the omission rule.
                # An oversized source is never rescued by masking: it falls
                # through to the omission rule exactly as it did before
                # masking existed.
                if not oversized and profile_masks_kind(kind, "absolute-path", self.profile):
                    masked_data = mask_absolute_paths(data)
                if masked_data is not None:
                    warnings.append(
                        {
                            "reason": "redacted-by-profile",
                            "target": relative,
                            "detail": "Absolute local path detected; evidence "
                            "published with those paths masked.",
                        }
                    )
                elif "absolute-path" in omit_on:
                    omit_reason = "absolute-path"
                    warnings.append(
                        {
                            "reason": "redacted-by-profile",
                            "target": relative,
                            "detail": "Absolute local path detected; evidence omitted by profile.",
                        }
                    )
            published = data if masked_data is None else masked_data
            # Omitted evidence bytes never enter the Bundle.  Scan every item
            # that can be published (including a later truncated item), while
            # allowing the profile to withhold sensitive source-only artifacts.
            # The scan reads the bytes that will be written, not the source, so
            # masking can never launder a secret past it.
            if omit_reason is None:
                match = _secret_match(published, fail_on)
                if match:
                    raise SecretScanError(relative, match)
            if omit_reason:
                item["status"] = "omitted"
                item["omitted_reason"] = omit_reason
                disclosure.append({"path": relative, "reason": omit_reason})
            elif len(published) > max_item_bytes:
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
                contents[relative] = published
                if masked_data is not None:
                    # `sha256` and `bytes` keep describing the source, so the
                    # Evidence ID and the cross-profile link to a local-v0
                    # Bundle are unchanged. The masked pair describes what a
                    # recipient can actually hash.
                    item["status"] = "masked"
                    item["masked_sha256"] = hashlib.sha256(masked_data).hexdigest()
                    item["masked_bytes"] = len(masked_data)
                    masked.append({"path": relative, "rule": "absolute-path"})
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
                if item["kind"] == required_kind and _evidence_is_published(item)
            ]
            if not matching:
                warnings.append(
                    {
                        "reason": "profile-required-evidence-missing",
                        "target": required_kind,
                        "detail": f"No evidence item of required kind {required_kind!r} was included.",
                    }
                )
        return EvidenceCollection(items, contents, disclosure, warnings, masked)


_FINDING_MARKER = re.compile(
    r"^.{0,9}?(?P<marker>\[P(?P<severity>[0-9])\])\s+(?P<summary>.+?)\s*$",
    re.MULTILINE,
)
_FINDING_MARKER_ATTEMPT = re.compile(
    r"^.{0,9}?(?P<marker>\[P[^\]]*\])", re.MULTILINE
)
# A bare severity marker anywhere in a cell. Goal Tracker tables put the marker
# mid-cell rather than at the start of a line, so the line-anchored patterns
# above do not apply.
_FINDING_MARKER_TOKEN = re.compile(r"\[P(?P<severity>[0-9])\]")


def _finding_key(severity: str, summary: str) -> str:
    """Return a stable internal key without exposing review prose in the Bundle.

    Absolute home paths are folded to the mask placeholder before hashing, so a
    finding keeps one identity whether it is read from a source review or from
    the masked copy a profile published. `codex review` names the faulted file
    in the finding summary, so without this the same finding would carry
    different ids in a Run's `local-v0` and `public-v1` Bundles -- and a
    maintainer holding both could not line them up, which is the whole point of
    asking the author for the fuller profile.
    """
    unmasked = _ABSOLUTE_HOME_PATH.sub(MASKED_HOME_PLACEHOLDER, summary)
    normalized = re.sub(r"\s+", " ", unmasked.strip().lower())
    return f"{severity}:{normalized}"


def _finding_id(round_index: int, severity: str, key: str) -> str:
    """Return the stable identity of a finding first seen in a given round.

    Shared by the compiler, which mints these, and the validator, which
    re-derives them to check a lifecycle claim against the review it points at.
    A second copy of this rule would let the two disagree silently.
    """
    return "finding-" + hashlib.sha256(
        canonical_json_bytes({"round": round_index, "severity": severity, "key": key})
    ).hexdigest()[:16]


@dataclass(frozen=True)
class ReviewFacts:
    """What one round-review artifact says, parsed once for both readers.

    The compiler decides a finding's lifecycle from these facts and the
    validator re-checks a lifecycle claim against them, so they are derived
    here rather than in each. When only the compiler knew how to parse a
    review, the validator could confirm a `resolved` claim against an empty or
    malformed review -- neither of which is the "later parseable review result"
    spec section G requires.
    """

    # "Parseable" in spec section G's sense is `present and not
    # malformed_markers`. It is not exposed as one property because both
    # readers need to tell the two apart: an absent review and an unreadable
    # one fail for different reasons and say so differently.
    present: bool
    malformed_markers: Tuple[str, ...]
    markers: Tuple[Tuple[str, str], ...]

    def finding_ids(self, found_round: int) -> set:
        """The identities these markers would mint for a given found round."""
        return {
            _finding_id(found_round, severity, _finding_key(severity, summary))
            for severity, summary in self.markers
        }


_CANONICAL_MARKER_TOKEN = re.compile(r"\[P[0-9]\]")


def first_review_marker(
    text: str, canonical_only: bool = False
) -> Optional[Dict[str, Any]]:
    """Return the first review marker in ``text``, or None if there is none.

    This is the single definition of "where is a review marker", and Loop's
    Stop hook reads it through `scripts/review-markers.py` rather than keeping
    its own. The hook used to re-implement the grammar in awk, and the two
    drifted three times: on whether a marker had to *fit* inside ten columns or
    merely *start* there, on byte offsets versus character offsets for non-ASCII
    prefixes, and on a token spanning a line break. Each divergence let the hook
    record "no finding was reported" about a review this module reads as
    reporting one, which resolves every finding still open in the Run.

    ``canonical_only`` selects `_FINDING_MARKER`, an actionable `[P0]`-`[P9]`
    finding line -- what the hook extracts. The default selects
    `_FINDING_MARKER_ATTEMPT`, canonical *or* malformed, which is exactly the
    set `parse_review_result` reacts to, and so exactly what must be absent
    before anyone may call a review clean.

    ``line`` is 1-based and derived from the match offset, so the caller never
    counts positions a second time. ``offset`` is the character offset of the
    start of the marker's line -- both patterns anchor on ``^``, which in
    MULTILINE mode matches only after ``\n``, so slicing the scanned text at
    ``offset`` yields the marker's line and everything after it without any
    reader having to translate a line number into some other view of the text.
    """
    pattern = _FINDING_MARKER if canonical_only else _FINDING_MARKER_ATTEMPT
    match = pattern.search(text)
    if match is None:
        return None
    marker = match.group("marker")
    return {
        "line": text.count("\n", 0, match.start("marker")) + 1,
        "offset": match.start(),
        "marker": marker,
        "canonical": _CANONICAL_MARKER_TOKEN.fullmatch(marker) is not None,
    }


def parse_review_result(text: Optional[str]) -> ReviewFacts:
    """Read a round review result into the facts both readers need."""
    if text is None or not text.strip():
        return ReviewFacts(present=False, malformed_markers=(), markers=())

    matches = list(_FINDING_MARKER.finditer(text))
    valid_spans = {(m.start("marker"), m.end("marker")) for m in matches}
    malformed: List[str] = []
    for attempt in _FINDING_MARKER_ATTEMPT.finditer(text):
        token = attempt.group("marker")
        span = (attempt.start("marker"), attempt.end("marker"))
        if span not in valid_spans and token not in malformed:
            malformed.append(token)

    markers = tuple(
        (f"P{m.group('severity')}", m.group("summary")) for m in matches
    )
    return ReviewFacts(
        present=True, malformed_markers=tuple(malformed), markers=markers
    )


# Every line that declares the boundary, whatever it declares. The value is
# matched separately so a malformed declaration is *seen* rather than skipped
# over in favour of a later well-formed one.
_BUILD_FINISH_ROUND_LINE = re.compile(r"^build_finish_round=(.*)$", re.MULTILINE)
# A bounded value. The digit cap is what keeps int() total: CPython raises
# ValueError above 4300 digits, and a Bundle is not trusted input, so an
# unbounded conversion here turns a crafted marker into an unhandled failure
# instead of a verdict.
_BUILD_FINISH_ROUND_VALUE = re.compile(r"^([0-9]{1,9})[ \t]*$")


# One spelling of a round's artifact paths, so the coverage rule and the
# projection of that rule into the Bundle can never disagree about which file
# they are talking about.
def _round_summary_path(index: int) -> str:
    return f"round-{index}-summary.md"


def _round_review_path(index: int) -> str:
    return f"round-{index}-review-result.md"


def _path_is_published(status_by_path: Mapping[str, str], path: str) -> bool:
    """Return whether the Bundle carries readable bytes at this evidence path.

    A path absent from the mapping was never collected. One whose status is not
    `included` or `masked` is in the Bundle in name only. Both the coverage rule
    and the projection of that rule ask this question, and answering it in each
    of them separately is how a masked item ends up trusted in one place and
    ignored in the other.
    """
    return _evidence_is_published({"status": status_by_path.get(path)})


def review_phase_boundary(
    marker_text: Optional[str],
    recorded_indices: Optional[Iterable[int]] = None,
) -> Optional[int]:
    """Return the round implementation finished at, or None if unestablished.

    Read from the `.review-phase-started` marker, which the Stop hook writes as
    `build_finish_round=N` the moment a Run leaves implementation. Loop then
    numbers every review-phase artifact N+1 and upward, so this one fact says
    which rounds had to deliver work and which only reviewed it.

    The marker is ordinary hashed evidence, so both readers take it from the
    bytes the Bundle publishes rather than from a field the producer wrote into
    the manifest. That is the difference between a rule the recipient can check
    and one they have to take on trust.

    Because it is read out of a Bundle rather than out of a trusted Run, this
    accepts **exactly one** complete, bounded declaration naming a round the Run
    actually recorded. Everything else -- absent, withheld, malformed,
    duplicated, contradictory, oversized, or pointing at no recorded round --
    returns None. A boundary excuses a round from having to publish a summary,
    so an ambiguous one must not be resolved in the producer's favour: the
    caller then falls back to the stricter rule. Reading the first of two
    conflicting declarations was how `build_finish_round=0` next to
    `build_finish_round=1` could quietly excuse round 1.
    """
    if marker_text is None:
        return None
    declarations = _BUILD_FINISH_ROUND_LINE.findall(marker_text)
    if len(declarations) != 1:
        # No declaration says nothing; two say two things. Neither establishes
        # a boundary, and picking one of two would be a guess.
        return None
    value_match = _BUILD_FINISH_ROUND_VALUE.match(declarations[0])
    if value_match is None:
        return None
    boundary = int(value_match.group(1))
    if recorded_indices is not None and boundary not in set(recorded_indices):
        # A boundary that names no recorded round describes some other Run.
        return None
    return boundary


def round_coverage_gaps(
    rounds: Sequence[Mapping[str, Any]],
    status_by_path: Mapping[str, str],
    build_finish_round: Optional[int] = None,
) -> List[Dict[str, str]]:
    """Return the round-evidence gaps in a Bundle, as reason records.

    Evaluated from the recorded rounds and each artifact's status, so the
    compiler and the validator reach the same conclusion from the same inputs.
    The validator previously read this off ``integrity.compile_warnings``,
    which meant deleting a warning and re-hashing made the gap disappear: the
    producer's account of itself was the only thing being checked.

    ``status_by_path`` maps an evidence path to its status; a path absent from
    the mapping was never collected, and one whose status is not ``included``
    or ``masked`` is in the Bundle in name only.

    The rule is per round, and what a round owes depends on what kind of round
    it is (ADR-0007, spec section H):

    - every recorded round needs some evidence of what happened in it;
    - an **implementation round** (``index <= build_finish_round``) delivered
      work, so it must publish a summary;
    - a round that recorded a summary must be **covered**: a published review
      result at its own index or a later recorded one. `codex review` reviews
      the cumulative diff from the Run's base commit, so a later review covers
      the earlier work -- which is why cancel-after-review, whose round 0 is
      reviewed in round 1, is a sound Run and not a gap;
    - a **review-phase round** (``index > build_finish_round``) records a
      review, not new work, and owes no summary. Without that carve-out a clean
      re-review -- the artifact that closes a finding -- would turn every Run
      that passed it `incomplete` (issue #33).

    ``build_finish_round`` of None means the Bundle could not establish the
    boundary, and the older, stricter rule applies unchanged: the final round
    needs both artifacts.
    """
    gaps: List[Dict[str, str]] = []
    indices = sorted(round_data["index"] for round_data in rounds)
    if not indices:
        return gaps

    def included(path: str) -> bool:
        return _path_is_published(status_by_path, path)

    def state_of(path: str) -> str:
        return "absent" if path not in status_by_path else "omitted or truncated"

    def gap(target: str, detail: str) -> None:
        gaps.append(
            {
                "reason": "profile-required-evidence-missing",
                "target": target,
                "detail": detail,
            }
        )

    # Every recorded round needs some evidence of what happened in it.
    for index in indices:
        if included(_round_summary_path(index)) or included(_round_review_path(index)):
            continue
        gap(
            f"round-{index}",
            "Round "
            + str(index)
            + " has neither a summary nor a review result in this Bundle, "
            "so what happened in it is unrecorded.",
        )

    if build_finish_round is None:
        # The Bundle does not say where implementation ended, so no round can
        # be excused as review-only. The final round needs both: it delivered
        # the work, and a Run cannot have exited the loop without that work
        # being summarized and reviewed.
        final_index = max(indices)
        for path, missing in (
            (_round_summary_path(final_index), "summary"),
            (_round_review_path(final_index), "review result"),
        ):
            if included(path):
                continue
            gap(
                path,
                "Final round "
                + str(final_index)
                + " "
                + missing
                + " is "
                + state_of(path)
                + "; the delivered work is unrecorded in this Bundle.",
            )
        return gaps

    for index in indices:
        summary = _round_summary_path(index)
        if index <= build_finish_round and not included(summary):
            gap(
                summary,
                "Implementation round "
                + str(index)
                + " summary is "
                + state_of(summary)
                + "; the work it delivered is unrecorded in this Bundle.",
            )
        # A summary the Run recorded is work, whichever phase it fell in, and
        # work is only evidenced once a review has covered it. Withheld here
        # too: a round whose summary this profile does not publish still had
        # work in it.
        if summary not in status_by_path:
            continue
        if any(included(_round_review_path(later)) for later in indices if later >= index):
            continue
        gap(
            _round_review_path(index),
            "Round "
            + str(index)
            + " recorded a summary that no review result at round "
            + str(index)
            + " or later covers in this Bundle; its work is unreviewed.",
        )
    return gaps


# The three round kinds, in one place. `ROUND_KIND_UNKNOWN` is the value a
# Bundle carries when it cannot establish the boundary, and it is deliberately
# a stated fact rather than an absent field: "this Bundle does not say" is
# itself something a recipient needs to read. The schema's enum is checked
# against this tuple by tests/proof_contract, so the two cannot drift.
ROUND_KIND_IMPLEMENTATION = "implementation"
ROUND_KIND_REVIEW_PHASE = "review_phase"
ROUND_KIND_UNKNOWN = "unknown"
ROUND_KINDS = (
    ROUND_KIND_IMPLEMENTATION,
    ROUND_KIND_REVIEW_PHASE,
    ROUND_KIND_UNKNOWN,
)


def round_projection(
    rounds: Sequence[Mapping[str, Any]],
    status_by_path: Mapping[str, str],
    build_finish_round: Optional[int],
) -> List[Dict[str, Any]]:
    """Return each round carrying the phase and coverage facts the rule uses.

    Issue #30 asked for "covered by" to be modelled rather than inferred, so a
    recipient can read which review covers which round instead of reconstructing
    it. Both facts are derived, never asserted: the Validator recomputes them
    from the same evidence statuses and the same published marker and rejects a
    Bundle whose manifest disagrees. A producer-declared round kind would be the
    `integrity.compile_warnings` mistake again -- an account of itself that the
    only check consults.

    `kind` is `unknown` when the Bundle cannot establish the boundary; that is a
    fact about this Bundle, not a licence, and the stricter rule applies.
    """
    indices = sorted(round_data["index"] for round_data in rounds)

    projected: List[Dict[str, Any]] = []
    for index in indices:
        if build_finish_round is None:
            kind = ROUND_KIND_UNKNOWN
        elif index <= build_finish_round:
            kind = ROUND_KIND_IMPLEMENTATION
        else:
            kind = ROUND_KIND_REVIEW_PHASE
        covering = [
            later
            for later in indices
            if later >= index
            and _path_is_published(status_by_path, _round_review_path(later))
        ]
        projected.append(
            {
                "index": index,
                "kind": kind,
                "reviewed_by": covering[0] if covering else None,
            }
        )
    return projected


def _waiver_targets(goal_tracker: Optional[str]) -> List[Tuple[str, int]]:
    """Return (severity, round) pairs the Goal Tracker explicitly queued.

    A waiver is a section move plus a ``[P0-9]`` marker, both structured
    signals ADR-0002 admits. The row is identified by its severity marker and
    its ``Discovered Round`` column, never by its prose: a tracker row
    summarizes an issue in the author's own words ("only replaced literal
    spaces") while the review result names it differently ("Implement full slug
    normalization"), so matching on summary text would either never fire or
    require exactly the fuzzy matching the ADR rules out.

    Both tables spec section G names are read: ``Queued Side Issues``, whose
    round column is "Discovered Round", and ``Explicitly Deferred``, whose
    equivalent is "Deferred Since". A finding can be parked in either.
    """
    if not goal_tracker:
        return []
    targets: List[Tuple[str, int]] = []
    for heading, round_header in (
        ("Queued Side Issues", "discovered round"),
        ("Explicitly Deferred", "deferred since"),
    ):
        section = _first_heading_section(goal_tracker, heading)
        if not section:
            continue
        rows = _parse_table_rows(section)
        if not rows:
            continue
        header = [cell.strip().lower() for cell in rows[0]]
        if round_header not in header:
            continue
        round_column = header.index(round_header)
        for row in rows[1:]:
            if round_column >= len(row):
                continue
            found_round = _round_value(row[round_column])
            if found_round is None:
                continue
            for cell in row:
                for marker in _FINDING_MARKER_TOKEN.finditer(cell):
                    target = (f"P{marker.group('severity')}", found_round)
                    if target not in targets:
                        targets.append(target)
    return targets


def _append_unique(values: List[str], value: str) -> None:
    if value not in values:
        values.append(value)


def _withheld_review_findings(
    round_index: int,
    item: Mapping[str, Any],
    text: Optional[str],
    known_ac_ids: Sequence[str],
) -> List[Dict[str, Any]]:
    """Record that a withheld review raised findings, without claiming more.

    The review is in the manifest but its bytes are not in the Bundle, because
    the profile omitted or truncated the item. Dropping its findings made the
    Bundle read as if the Run had found nothing, and under `public-v0` that is
    not incidental: `codex review` cites the file it faults by absolute path,
    so in the M4 dogfood corpus every one of the seven review results that
    reported a finding contained an absolute home path, and the public path
    rule withheld every one of them. Every public Bundle listed no findings at
    all while its local counterpart listed them.

    So the finding's existence is recorded and nothing else is. `unverifiable`
    is the honest state (spec section G: a lifecycle no evidence in this Bundle
    can establish), the id is a hash of round, severity and normalized summary
    so no review prose enters the Bundle, and these findings never join
    ``active`` -- a later review may not clear a finding whose own evidence
    this profile withheld (D9). The direction is one-way on purpose: withheld
    evidence may show that a problem existed, never that one was fixed.

    A malformed marker fails this reader closed, exactly as it fails the
    included-review reader: partial facts from a review that also contains
    markers the parser rejected are not facts, and the two readers must not
    disagree about that just because one review's bytes were withheld. The
    malformed tokens themselves are never reported here -- they are content
    from bytes the profile chose not to publish.
    """
    facts = parse_review_result(text)
    if not facts.present:
        return []
    if facts.malformed_markers:
        return []
    known = set(known_ac_ids)
    findings: List[Dict[str, Any]] = []
    by_key: Dict[str, Dict[str, Any]] = {}
    for severity, summary in facts.markers:
        key = _finding_key(severity, summary)
        ac_refs = [
            identifier for identifier in _ac_ids(summary) if identifier in known
        ]
        existing = by_key.get(key)
        if existing is not None:
            for identifier in ac_refs:
                _append_unique(existing["ac_refs"], identifier)
            continue
        finding = {
            "id": _finding_id(round_index, severity, key),
            "severity": severity,
            "status": "unverifiable",
            "found_round": round_index,
            "evidence_refs": [item["id"]],
            "ac_refs": ac_refs,
        }
        by_key[key] = finding
        findings.append(finding)
    return findings


def _derive_findings(
    run: RunRecord,
    evidence_by_path: Mapping[str, Mapping[str, Any]],
    published_contents: Optional[Mapping[str, bytes]] = None,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]], bool]:
    """Derive conservative finding lifecycle facts from retained review results.

    Findings are read out of ``published_contents`` -- the bytes the Bundle
    will actually carry -- not out of the source file. A finding's identity
    hashes its summary text, and the Validator re-derives that identity from
    the file it finds in the Bundle when it checks a `resolved` claim against
    the review it cites. Reading the source here would mint a different id
    whenever a masked path appears inside a finding summary, which is the
    common case, and the Validator's "this review still records the finding"
    check would silently stop matching: a false green rather than a failure.
    """
    findings: List[Dict[str, Any]] = []
    warnings: List[Dict[str, str]] = []
    parseable = True
    active: Dict[str, Dict[str, Any]] = {}
    known_ac_ids = {criterion["id"] for criterion in run.acceptance_criteria}
    published = published_contents or {}

    def review_text(relative: str, source: Path) -> Optional[str]:
        data = published.get(relative)
        if data is None:
            # Only reachable for an item the Bundle does not publish, where
            # the source is all there is; a withheld review's findings are
            # recorded as unverifiable and never linked, so no Validator
            # re-derivation depends on this text.
            return _read_text(source)
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return None

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
        if not _evidence_is_published(item):
            if item is None and not active:
                # No review result for this round and no finding waiting on
                # one, so this is not a failed re-review.
                #
                # An intermediate round can legitimately lack one: work
                # summarized in round N and reviewed in round N+1 is reviewed
                # work, and cancel-after-review is a real Run shaped exactly
                # that way. ADR-0007 makes that the written rule, and
                # round_coverage_gaps enforces it for the compiler and the
                # validator alike; this branch only declines to read a
                # lifecycle conclusion out of a review that is not there.
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
            if item is not None:
                findings.extend(
                    _withheld_review_findings(
                        round_index,
                        item,
                        review_text(relative, path),
                        sorted(known_ac_ids),
                    )
                )
            continue
        facts = parse_review_result(review_text(relative, path))
        if not facts.present:
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

        malformed_markers = list(facts.malformed_markers)
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
        for severity, summary in facts.markers:
            key = _finding_key(severity, summary)
            ac_refs = [identifier for identifier in _ac_ids(summary) if identifier in known_ac_ids]
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
                    # Record which round closed it and which review said so.
                    # Both are already known here and were previously dropped,
                    # which left the Explorer rendering "not linked" for every
                    # resolved finding. They are structural facts -- the marker
                    # is absent from this round's review result -- so recording
                    # them stays inside ADR-0002. The fix landed in the work of
                    # this round, and this round's review is the re-review that
                    # confirms it; neither is inferred from review prose.
                    finding["fix_round"] = round_index
                    finding["re_review_ref"] = item["id"]
            next_active: Dict[str, Dict[str, Any]] = {}
            for key, (severity, ac_refs) in current.items():
                finding = active.get(key)
                if finding is None:
                    identifier = _finding_id(round_index, severity, key)
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

    # A finding the Goal Tracker explicitly queued is waived rather than left
    # open. Only a still-open finding can be waived: a waiver cannot overturn a
    # resolved finding, and it must not paper over one whose lifecycle this
    # profile could not verify. The tracker has to be retained under the active
    # profile, or the waiver is not profile-verifiable.
    tracker_item = evidence_by_path.get("goal-tracker.md")
    # Waivers are read from the source tracker text, which is sound only while
    # the tracker cannot be masked. The v0 profile schema enforces that by
    # allowing no kind but `round_review_result` in `mask_kinds`; widening it
    # means moving this read onto the published bytes too.
    if _evidence_is_published(tracker_item):
        for severity, found_round in _waiver_targets(run.goal_tracker_text):
            matches = [
                finding
                for finding in findings
                if finding["severity"] == severity
                and finding["found_round"] == found_round
                and finding["status"] == "open"
            ]
            # Exactly one, or none. A waiver removes a blocker, so an ambiguous
            # row -- two open P2s from the same round -- must not silently
            # clear both when the tracker only accounted for one.
            if len(matches) != 1:
                if len(matches) > 1:
                    warnings.append(
                        {
                            "reason": "unparseable-artifact",
                            "target": "goal-tracker.md",
                            "detail": "Queued Side Issues row for "
                            + severity
                            + " in round "
                            + str(found_round)
                            + " matches more than one open finding; no waiver applied.",
                        }
                    )
                continue
            finding = matches[0]
            finding["status"] = "waived"
            finding["waived_ref"] = tracker_item["id"]
            _append_unique(finding["evidence_refs"], tracker_item["id"])

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
        profile: str = DEFAULT_EXPORT_PROFILE,
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
        explorer_assets = _explorer_asset_bytes()
        profile_omit_on = set((profile.get("secret_scan", {}) or {}).get("omit_on", []))
        evidence = EvidenceCompiler(run, profile).collect()
        evidence_by_path = {item["path"]: item for item in evidence.items}
        warnings = list(run.warnings) + list(evidence.warnings)
        published_evidence_bytes = sum(len(content) for content in evidence.contents.values())
        state_relative_path = run.state_path.relative_to(run.run_dir).as_posix()
        # State-derived projections are safe only when the complete source
        # artifact is present in the Bundle.  A truncated item has no raw file
        # to link back to, just like a profile-omitted item; retaining its
        # frontmatter (especially free-form circuit-breaker values) would let
        # arbitrary source text bypass the per-item size/redaction boundary.
        state_included = (
            _evidence_is_published(evidence_by_path.get(state_relative_path))
        )
        tracker_included = (
            _evidence_is_published(evidence_by_path.get("goal-tracker.md"))
        )
        # Goal and acceptance-criteria text are projections of file evidence.
        # Once the source item is absent from the Bundle, retaining those
        # projections would let source prose bypass its disclosure boundary.
        projected_goal = (
            run.goal
            if _evidence_is_published(evidence_by_path.get("plan.md"))
            else ""
        )
        projected_criteria = run.acceptance_criteria if tracker_included else []
        projected_events = run.events
        if not state_included:
            # Circuit-breaker fields come directly from state frontmatter.
            # Withhold the entire event when that source artifact is not
            # published, rather than letting an unknown future state value
            # escape through an optional event property.
            projected_events = [
                {**event, "at": None}
                for event in run.events
                if event.get("kind") != "circuit_breaker"
            ]
        if not tracker_included:
            # Plan-evolution facts are projections of the Goal Tracker just
            # like acceptance criteria.  Do not retain even their structured
            # shape when that source artifact was omitted, truncated, or is
            # otherwise unavailable in the Bundle.
            projected_events = [
                event
                for event in projected_events
                if event.get("kind") not in {"plan_evolution", "replan"}
            ]

        def event_evidence_paths(event: Mapping[str, Any]) -> List[str]:
            kind = event.get("kind")
            round_index = event.get("round")
            if kind == "setup":
                return ["plan.md"]
            if kind == "round" and isinstance(round_index, int):
                return [
                    f"round-{round_index}-summary.md",
                    f"round-{round_index}-contract.md",
                ]
            if kind == "mainline_verdict" and isinstance(round_index, int):
                return [f"round-{round_index}-review-result.md"]
            if kind in {"plan_evolution", "replan"}:
                return ["goal-tracker.md"]
            if kind == "circuit_breaker" or kind == "terminal":
                return [state_relative_path]
            if kind == "review_phase":
                return [".review-phase-started"]
            if kind == "finalize":
                return ["finalize-summary.md"]
            return []

        evidence_linked_events: List[Dict[str, Any]] = []
        for event in projected_events:
            linked_event = dict(event)
            references: List[str] = []
            for path in event_evidence_paths(linked_event):
                item = evidence_by_path.get(path)
                if _evidence_is_published(item):
                    _append_unique(references, item["id"])
            linked_event["evidence_refs"] = references
            evidence_linked_events.append(linked_event)
        projected_events = evidence_linked_events
        source = {
            "repo_name": _repo_name(self.repo_root, run.run_dir),
            "base_commit": run.base_commit,
            "head_commit": run.head_commit,
            "reviewed_commit": run.reviewed_commit,
            "loop_version": str(run.state.get("loop_version") or "unknown")
            if state_included
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
            return [item["id"]] if _evidence_is_published(item) else []

        tracker_ref = evidence_refs_for_path("goal-tracker.md")
        review_refs = [
            item["id"]
            for item in evidence.items
            if item["kind"] == "round_review_result" and _evidence_is_published(item)
        ]
        summary_refs = [
            item["id"]
            for item in evidence.items
            if item["kind"] == "round_summary" and _evidence_is_published(item)
        ]
        findings, finding_warnings, findings_parseable = _derive_findings(
            run, evidence_by_path, evidence.contents
        )
        if not tracker_included:
            # Without the Goal Tracker, finding-to-AC links are not
            # profile-verifiable.  Keep the finding lifecycle facts, but do
            # not emit dangling acceptance-criterion references.
            for finding in findings:
                finding["ac_refs"] = []
        warnings.extend(finding_warnings)
        # Round-evidence coverage, evaluated by the shared rule so the
        # validator reaches the same conclusion from the same inputs rather
        # than trusting the warnings recorded here. The boundary is read from
        # the bytes this Bundle publishes, not from the source Run, so a
        # profile that withholds the marker leaves the compiler on the same
        # stricter fallback the recipient will be on.
        round_status_by_path = {
            path: item.get("status", "") for path, item in evidence_by_path.items()
        }
        marker_item = evidence_by_path.get(REVIEW_PHASE_MARKER)
        build_finish_round = review_phase_boundary(
            _decode_text(evidence.contents.get(REVIEW_PHASE_MARKER))
            if _evidence_is_published(marker_item)
            else None,
            [round_data["index"] for round_data in run.rounds],
        )
        projected_rounds = round_projection(
            run.rounds, round_status_by_path, build_finish_round
        )
        coverage_gaps = round_coverage_gaps(
            run.rounds, round_status_by_path, build_finish_round
        )
        if coverage_gaps:
            findings_parseable = False
            warnings.extend(coverage_gaps)

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
        # A deferral is only accepted when the Plan Evolution Log carries the
        # row it implies, and that row has to name this criterion at that
        # round. Matching on the round alone was not enough: every Run opens
        # with a "| 0 | Initial plan |" row, so any deferral citing round 0 was
        # authorized by a row that replanned nothing. A deferral nobody
        # replanned is an AC quietly dropped from the required set, which is
        # the one way this deriver could manufacture a green result out of
        # nothing (D5).
        # A round cited anywhere in the tracker only means something if the Run
        # recorded it.
        recorded_round_indices = {
            round_data["index"] for round_data in run.rounds
        }
        # The cited round must also be one the Run actually recorded. Without
        # this a Deferred Since of 999 plus an Impact on AC row for round 999
        # authorized itself: two rows agreeing with each other about a round
        # that never happened removed the criterion and produced `accept`.
        replan_pairs = {
            (ac_id, round_index)
            for ac_id, round_index in _replan_ac_rounds(run.goal_tracker_text)
            if round_index in recorded_round_indices
        }
        deferred_ac_ids = {
            item["ac_id"]
            for item in run.deferred
            if (item["ac_id"], item.get("since_round")) in replan_pairs
        }
        uncited_deferrals = {
            item["ac_id"] for item in run.deferred
        } - deferred_ac_ids
        # A Verified Round only verifies something if the Run recorded that
        # round. "999" parses as a round and names none, so without this a
        # tracker could claim verification in a round that never happened.
        for criterion in projected_criteria:
            ac_id = criterion["id"]
            verified_in = run.completed_ac_ids.get(ac_id)
            completed = verified_in is not None and verified_in in recorded_round_indices
            claimed_unrecorded_round = (
                verified_in is not None and verified_in not in recorded_round_indices
            )
            supporting = tracker_ref + review_refs + summary_refs if completed and tracker_ref else []
            if claimed_unrecorded_round:
                status = "unverifiable"
                reason = (
                    "Completed and Verified cites round "
                    + str(verified_in)
                    + ", which this Run did not record."
                )
            elif completed and tracker_ref:
                status = "met"
                reason = "Recorded in the Completed and Verified table."
            elif completed:
                status = "unverifiable"
                reason = "Completion evidence is unavailable in this verification profile."
            elif ac_id in run.unverified_completion_ac_ids:
                # Claimed complete, but the row's Verified Round is blank or
                # still reads "pending". Spec section G makes the Verified
                # Round part of what `met` means.
                status = "unverifiable"
                reason = (
                    "Completed and Verified row records no Verified Round, so "
                    "the completion is not evidenced as verified."
                )
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
            elif ac_id in uncited_deferrals:
                # Deliberately not "deferred": it stays in the required set, so
                # an uncited deferral costs the Run its accept rather than
                # silently shrinking what had to be delivered.
                status = "unverifiable"
                reason = (
                    "Deferral cites no Plan Evolution Log round, so it was not "
                    "accepted as a deferral."
                )
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
                item["kind"] == required_kind and _evidence_is_published(item)
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
            "explorer": {"assets": _explorer_asset_hashes(explorer_assets)},
            "source": source,
            "specification": {"goal": projected_goal, "acceptance_criteria": projected_criteria},
            "run": {
                "session_timestamp": run.session_timestamp if state_included else None,
                "terminal_state": run.terminal_state,
                "rounds": projected_rounds,
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
            "integrity": {
                "status": _integrity_status(warnings),
                "compile_warnings": warnings,
            },
            "disclosure": {
                "omitted": evidence.disclosure,
                "field_redactions": list(profile.get("field_redactions", [])),
                "masked": evidence.masked,
            },
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
            bundle["integrity"]["status"] = _integrity_status(warnings)
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
    """Write a canonical manifest, offline Explorer, and raw evidence safely."""
    target = Path(output_dir).expanduser().resolve()
    proof_json, proof_data = _bundle_document_bytes(bundle)
    explorer_assets = _explorer_asset_bytes()
    declared_assets = _declared_explorer_asset_hashes(bundle)
    actual_assets = _explorer_asset_hashes(explorer_assets)
    for name in _EXPLORER_ASSET_NAMES:
        if declared_assets[name] != actual_assets[name]:
            raise BundleWriteError(
                "Proof Bundle explorer.assets does not match the packaged "
                f"Explorer asset {name}."
            )
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
        proof_path.write_bytes(proof_json)
        (target / "proof-data.js").write_bytes(proof_data)
        for name, contents in explorer_assets.items():
            (target / name).write_bytes(contents)
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

    def _explorer_bytes(self) -> int:
        """Measure regular Explorer files in the received Bundle, not this checkout."""
        total = 0
        for name in _EXPLORER_ASSET_NAMES:
            path = self.bundle_dir / name
            try:
                if path.is_file() and not path.is_symlink():
                    total += path.stat().st_size
            except OSError:
                continue
        return total

    def _check_lifecycle_coherence(
        self,
        report: "ValidationReport",
        finding: Mapping[str, Any],
        status: str,
        linked: Mapping[str, Any],
        target: str,
    ) -> None:
        """Fail a cleared finding whose link does not substantiate the claim."""
        tracker_text: Optional[str] = None
        review_text: Optional[str] = None
        if status == "waived":
            tracker_text = _read_text(self.bundle_dir / "evidence" / "goal-tracker.md")
        else:
            linked_path = linked.get("path")
            if isinstance(linked_path, str):
                review_text = _read_text(self.bundle_dir / "evidence" / linked_path)
        detail = _lifecycle_incoherence(
            finding, status, linked, tracker_text, review_text
        )
        if detail is None:
            return
        report.status = "invalid"
        report.reasons.append(
            {"reason": "schema-violation", "target": target, "detail": detail}
        )

    def _check_round_projection(
        self,
        report: "ValidationReport",
        recorded_rounds: Any,
        status_by_path: Mapping[str, str],
        build_finish_round: Optional[int],
    ) -> None:
        """Fail a Bundle whose round phase or coverage facts it cannot support.

        A Bundle written before these facts existed carries neither, and stays
        valid: the field is absent, so nothing is being claimed. What is
        rejected is a Bundle that states a round's kind or covering review and
        disagrees with the evidence it ships.
        """
        if not isinstance(recorded_rounds, list):
            return
        expected_by_index = {
            entry["index"]: entry
            for entry in round_projection(
                [
                    round_data
                    for round_data in recorded_rounds
                    if isinstance(round_data, Mapping)
                    and isinstance(round_data.get("index"), int)
                ],
                status_by_path,
                build_finish_round,
            )
        }
        for round_data in recorded_rounds:
            if not isinstance(round_data, Mapping):
                continue
            expected = expected_by_index.get(round_data.get("index"))
            if expected is None:
                continue
            for field_name in ("kind", "reviewed_by"):
                if field_name not in round_data:
                    continue
                if round_data[field_name] == expected[field_name]:
                    continue
                report.status = "invalid"
                report.reasons.append(
                    {
                        "reason": "schema-violation",
                        "target": "run.rounds[" + str(round_data["index"]) + "]."
                        + field_name,
                        "detail": "Round "
                        + str(round_data["index"])
                        + " declares "
                        + field_name
                        + " "
                        + json.dumps(round_data[field_name])
                        + ", but this Bundle's evidence derives "
                        + json.dumps(expected[field_name])
                        + ".",
                    }
                )

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
            if status in ("included", "masked") and omitted_reason is not None:
                profile_violation(
                    relative,
                    "Published evidence must not carry an omission reason.",
                )
            if status == "masked":
                # Re-derived from the profile rather than believed: a Bundle
                # that declares an item masked under a profile with no masking
                # rule for that class and kind is claiming a licence the
                # profile never granted.
                if not profile_masks_kind(kind, "absolute-path", profile):
                    profile_violation(
                        relative,
                        "Evidence is declared masked without a matching profile "
                        "masking rule for its kind.",
                    )
                masked_digest = _published_digest(item)
                masked_count = _published_byte_count(item)
                if masked_digest is None or masked_count is None:
                    report.status = "invalid"
                    report.reasons.append(
                        {
                            "reason": "schema-violation",
                            "target": relative,
                            "detail": "Masked evidence must declare "
                            "'masked_sha256' and a non-negative 'masked_bytes'.",
                        }
                    )
                    continue
                if masked_digest == digest:
                    # Masking that changed nothing means the source needed no
                    # masking, so the status misdescribes the item.
                    profile_violation(
                        relative,
                        "Masked evidence must differ from its source; "
                        "'masked_sha256' equals 'sha256'.",
                    )
            if status == "omitted":
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
            elif _evidence_is_published(item):
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
                # A masked item's file is the masked copy, so it is hashed
                # against the masked pair. `sha256` still names the source, and
                # nothing in the Bundle can corroborate that -- only a
                # `local-v0` Bundle of the same Run can, which is the stated
                # limit of masked publication (ADR-0004).
                expected_digest = _published_digest(item)
                expected_bytes = _published_byte_count(item)
                actual_digest = hashlib.sha256(data).hexdigest()
                if actual_digest != expected_digest or len(data) != expected_bytes:
                    report.status = "invalid"
                    report.reasons.append({"reason": "hash-mismatch", "target": relative, "detail": "Evidence bytes or declared size differ."})
                if (
                    "absolute-path" in omit_on or status == "masked"
                ) and _has_absolute_path(data):
                    profile_violation(
                        relative,
                        "Published evidence contains an absolute home path that "
                        "the selected profile requires to be masked or omitted.",
                    )
                else:
                    match = _secret_match(data, fail_on)
                    if match:
                        profile_violation(
                            relative,
                            f"Included evidence matches the profile secret class {match!r}.",
                        )
            elif status == "truncated":
                # Derived from the item itself, not from the compiler's
                # warning list. Reading `truncated-evidence` out of
                # integrity.compile_warnings meant a hand-edited Bundle could
                # declare an item truncated, drop the warning, and verify
                # `valid` -- the exporter's own account of itself was the only
                # thing being checked. Spec section J makes truncation an
                # incomplete Bundle regardless of what the producer recorded.
                #
                # The status has to be set here too: recording the reason alone
                # left a re-hashed Bundle reporting `valid` at exit 0 while
                # listing truncated-evidence, which is the same trust in the
                # producer wearing a different hat. `invalid` outranks
                # `incomplete`, so an independently invalid Bundle keeps that.
                if report.status != "invalid":
                    report.status = "incomplete"
                report.reasons.append(
                    {
                        "reason": "truncated-evidence",
                        "target": relative,
                        "detail": "Evidence is truncated, so the Bundle is incomplete.",
                    }
                )

        def require_evidence(
            identifier: str, target: str, included_only: bool = False
        ) -> None:
            item = ids.get(identifier)
            if item is None:
                report.status = "invalid"
                report.reasons.append({"reason": "dangling-reference", "target": target, "detail": f"Unknown evidence reference {identifier!r}."})
            elif included_only and not _evidence_is_published(item):
                report.status = "invalid"
                report.reasons.append(
                    {
                        "reason": "schema-violation",
                        "target": target,
                        "detail": f"Evidence reference {identifier!r} must point to included evidence.",
                    }
                )

        for finding in bundle.get("findings", []):
            for identifier in finding.get("evidence_refs", []):
                require_evidence(identifier, f"finding:{finding.get('id', '?')}")
            # A lifecycle status that clears a finding has to carry the link
            # that justifies it, pointing at evidence the Bundle actually
            # includes. Without this a hand-edited Bundle could claim every
            # finding `resolved` with no re-review to show for it and still
            # verify clean -- the Explorer already refuses to display such a
            # claim as resolved, and the verifier should agree.
            status = finding.get("status")
            # The link must also be the right *kind* of evidence. Checking only
            # that it resolves to an included item let a resolved finding point
            # at plan.md: a plan cannot substantiate a re-review, and a review
            # result cannot substantiate a waiver.
            link_rule = {
                "resolved": ("re_review_ref", "round_review_result"),
                "waived": ("waived_ref", "goal_tracker"),
            }.get(status)
            if link_rule is not None:
                link_field, required_kind = link_rule
                target = f"finding:{finding.get('id', '?')}"
                link = finding.get(link_field)
                if not isinstance(link, str) or not link:
                    report.status = "invalid"
                    report.reasons.append(
                        {
                            "reason": "schema-violation",
                            "target": target,
                            "detail": f"A {status!r} finding must carry {link_field!r}.",
                        }
                    )
                else:
                    require_evidence(link, target, included_only=True)
                    linked = ids.get(link)
                    if linked is not None and linked.get("kind") != required_kind:
                        report.status = "invalid"
                        report.reasons.append(
                            {
                                "reason": "schema-violation",
                                "target": target,
                                "detail": f"{link_field!r} must reference {required_kind!r} evidence, not {linked.get('kind')!r}.",
                            }
                        )
                    elif linked is not None:
                        self._check_lifecycle_coherence(
                            report, finding, status, linked, target
                        )
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
        for event in bundle.get("run", {}).get("events", []):
            for identifier in event.get("evidence_refs", []):
                require_evidence(
                    identifier,
                    f"run.event:{event.get('kind', '?')}",
                    included_only=True,
                )
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
        # The masked declaration is reconciled exactly as the omitted one is:
        # issue #32 introduced `disclosure.masked` so a reader is never left
        # to tell "you cannot see this" from "you can see this, altered", and
        # an unreconciled declaration is one a producer can silently drop.
        # The rule is re-derived, not believed: v0 admits exactly one masking
        # rule, so every masked item declares `absolute-path`. The field may
        # be absent only in a Bundle that masks nothing, which is every
        # Bundle distributed before masking existed.
        expected_masked = {
            (item["path"], "absolute-path")
            for item in items
            if item.get("status") == "masked"
        }
        declared_masked = bundle.get("disclosure", {}).get("masked", [])
        actual_masked = {
            (item.get("path"), item.get("rule")) for item in declared_masked
        }
        if declared_masked or expected_masked:
            if (
                len(declared_masked) != len(actual_masked)
                or actual_masked != expected_masked
            ):
                profile_violation(
                    "disclosure.masked",
                    "Disclosure maskings must list each and only each masked evidence item with its rule.",
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
                and _evidence_is_published(item)
            ]
            if not matching:
                if report.status == "valid":
                    report.status = "incomplete"
                report.reasons.append({"reason": "profile-required-evidence-missing", "target": required_kind, "detail": f"Required evidence kind {required_kind!r} is absent."})

        # Round coverage is derived here from the same rule the compiler used,
        # not read out of integrity.compile_warnings below. Trusting those
        # warnings meant deleting one and re-hashing made the gap disappear:
        # a three-round Bundle whose middle round held only a contract then
        # verified `valid`. The producer's account of itself cannot be the only
        # thing checked.
        recorded_rounds = bundle.get("run", {}).get("rounds", [])
        round_status_by_path = {
            item.get("path", ""): item.get("status", "")
            for item in items
            if isinstance(item, Mapping)
        }
        marker_item = next(
            (
                item
                for item in items
                if isinstance(item, Mapping)
                and item.get("path") == REVIEW_PHASE_MARKER
            ),
            None,
        )
        build_finish_round = review_phase_boundary(
            _read_text(self.bundle_dir / "evidence" / REVIEW_PHASE_MARKER)
            if _evidence_is_published(marker_item)
            else None,
            [
                round_data["index"]
                for round_data in recorded_rounds
                if isinstance(round_data, Mapping)
                and isinstance(round_data.get("index"), int)
            ]
            if isinstance(recorded_rounds, list)
            else [],
        )
        # The same reason the gaps are recomputed applies to the phase and
        # coverage facts the manifest publishes: a round that declares itself
        # review-only owes no summary, so an unchecked declaration is a way to
        # excuse a missing one. Re-derive, then require the manifest to agree.
        self._check_round_projection(
            report, recorded_rounds, round_status_by_path, build_finish_round
        )
        for gap in round_coverage_gaps(
            recorded_rounds, round_status_by_path, build_finish_round
        ):
            if report.status == "valid":
                report.status = "incomplete"
            report.reasons.append(gap)

        for warning in bundle.get("integrity", {}).get("compile_warnings", []):
            report.warnings.append({"target": warning.get("target", ""), "detail": warning.get("detail", ""), "reason": warning.get("reason", "")})
            if (
                warning.get("reason") in _INTEGRITY_INCOMPLETE_REASONS
                and report.status == "valid"
            ):
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
            _published_byte_count(item) or 0
            for item in items
            if _evidence_is_published(item)
        )
        size_candidate = _bundle_without_size_budget_warning(bundle)
        size_warning = _size_budget_warning(
            profile,
            size_candidate,
            published_evidence_bytes,
            self._explorer_bytes(),
        )
        if size_warning is not None and not report_has_warning("size-budget-exceeded"):
            report.warnings.append(size_warning)
        declared_integrity = bundle.get("integrity", {})
        declared_status = (
            declared_integrity.get("status")
            if isinstance(declared_integrity, Mapping)
            else None
        )
        if (
            report.status != "invalid"
            and declared_status is not None
            and declared_status != report.status
        ):
            expected_status = report.status
            report.status = "invalid"
            report.reasons.append(
                {
                    "reason": _INTEGRITY_STATUS_MISMATCH_REASON,
                    "target": "integrity.status",
                    "detail": (
                        f"Declared integrity status {declared_status!r} does not match "
                        f"the validator result {expected_status!r}."
                    ),
                }
            )
        return report


def compile_bundle(
    run_dir: Union[str, os.PathLike[str]],
    output_dir: Union[str, os.PathLike[str]],
    profile: str = DEFAULT_EXPORT_PROFILE,
    repo_root: Optional[Union[str, os.PathLike[str]]] = None,
) -> Path:
    """Convenience function used by scripts and embedders."""
    bundle, evidence = BundleCompiler(run_dir, profile=profile, repo_root=repo_root).compile()
    return write_bundle(bundle, evidence, _output_outside_run(run_dir, output_dir))


def export_run(
    run_dir: Union[str, os.PathLike[str]],
    output_dir: Optional[Union[str, os.PathLike[str]]] = None,
    profile: str = DEFAULT_EXPORT_PROFILE,
    repo_root: Optional[Union[str, os.PathLike[str]]] = None,
) -> ExportResult:
    """Compile and write a Run, using the identity-addressed default if needed."""
    resolved_root = Path(repo_root).resolve() if repo_root else Path.cwd().resolve()
    bundle, evidence = BundleCompiler(run_dir, profile=profile, repo_root=resolved_root).compile()
    destination = Path(output_dir).expanduser() if output_dir else default_output_dir(resolved_root, bundle)
    return ExportResult(
        write_bundle(bundle, evidence, _output_outside_run(run_dir, destination)), bundle
    )


def _lifecycle_incoherence(
    finding: Mapping[str, Any],
    status: str,
    linked: Mapping[str, Any],
    tracker_text: Optional[str],
    review_text: Optional[str] = None,
) -> Optional[str]:
    """Return why a cleared finding's link fails to substantiate it, or None.

    Checking that the link resolves to included evidence of the right kind is
    not enough. A `resolved` finding could point at the very review that raised
    it, and a `waived` finding could point at a Goal Tracker holding no such
    record; both verified clean. The Bundle carries the evidence, so these
    claims can be checked against it rather than taken on trust.

    This is not tamper-proofing. Anyone who rewrites proof.json can rewrite the
    evidence and its hashes too; the anchor against that is comparing proof_id
    with the value the producer published, not any check inside the Bundle.
    What this does is make the Bundle internally coherent, so a claim it makes
    is answerable from what it contains.
    """
    found_round = finding.get("found_round")
    if status == "resolved":
        fix_round = finding.get("fix_round")
        if not isinstance(fix_round, int):
            return "A 'resolved' finding must record the round that fixed it."
        if isinstance(found_round, int) and fix_round <= found_round:
            return (
                f"A finding found in round {found_round} cannot be resolved by "
                f"round {fix_round}."
            )
        expected = f"round-{fix_round}-review-result.md"
        if linked.get("path") != expected:
            return (
                f"'re_review_ref' must reference {expected!r}, the review for "
                f"the recorded fix round, not {linked.get('path')!r}."
            )
        # Naming the right file is not the same as that file saying the right
        # thing. Spec section G resolves a finding when a later parseable
        # review no longer names it, so the review has to be read: a Bundle
        # could otherwise point at the correct later review while that review
        # still carries the original marker.
        facts = parse_review_result(review_text)
        # Spec section G resolves a finding against a later *parseable* review.
        # Checking only for the marker's absence accepted an empty review and
        # one whose markers are malformed as proof the finding went away --
        # in both cases nothing was read, which is not the same as reading
        # that the finding is gone. The compiler calls those `unverifiable`;
        # the validator has to agree rather than let them stand as `resolved`.
        if not facts.present:
            return (
                f"{expected!r} is empty or unreadable, so it cannot show the "
                "finding was resolved."
            )
        if facts.malformed_markers:
            return (
                f"{expected!r} has malformed finding markers ("
                + ", ".join(facts.malformed_markers)
                + "), so it cannot show the finding was resolved."
            )
        if finding.get("id") in facts.finding_ids(found_round):
            return (
                f"{expected!r} still records this finding, so it is not resolved."
            )
        return None

    # waived: the Goal Tracker has to carry the record spec section G requires.
    if not isinstance(found_round, int):
        return "A 'waived' finding must record the round it was found in."
    severity = finding.get("severity")
    if tracker_text is None:
        return "The referenced Goal Tracker could not be read to confirm the waiver."
    if (severity, found_round) not in _waiver_targets(tracker_text):
        return (
            f"The referenced Goal Tracker carries no Queued or Deferred record "
            f"for {severity} in round {found_round}."
        )
    return None


def validate_bundle(bundle_path: Union[str, os.PathLike[str]]) -> ValidationReport:
    """Convenience function used by scripts and tests."""
    return BundleValidator(bundle_path).validate()
