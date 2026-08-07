# Goal Tracker

<!--
This file tracks the ultimate goal, acceptance criteria, and plan evolution.
It prevents goal drift by maintaining a persistent anchor across all rounds.

RULES:
- IMMUTABLE SECTION: Do not modify after initialization
- MUTABLE SECTION: Update each round, but document all changes
- Every task must be in one of: Active, Completed, or Deferred
- Deferred items require explicit justification
-->

## IMMUTABLE SECTION
<!-- Do not modify after initialization -->

### Ultimate Goal

Provide a dependency-free Python module `ini_parser.py` that reads a minimal
INI configuration format into ordinary dictionaries, plus a pytest suite.

## Acceptance Criteria

### Acceptance Criteria
<!-- Each criterion must be independently verifiable -->
<!-- Claude must extract or define these in Round 0 -->


- AC1: `parse(text: str) -> dict` returns a mapping of section name to a
  mapping of key to value. Keys and section names are stripped of surrounding
  whitespace; values keep interior whitespace but lose surrounding whitespace.
- AC2: Lines whose first non-whitespace character is `#` or `;` are comments
  and are ignored. A `#` or `;` inside a value is part of the value, not the
  start of a comment.
- AC3: A key that appears before any section header belongs to the section
  named by the empty string.
- AC4: A duplicate key inside one section raises `DuplicateKeyError`, a
  subclass of `ValueError`, naming the section and the key. A duplicate
  section header is not an error: its keys merge into the existing section.
- AC5: A malformed line (no `=` and not a comment, blank line, or section
  header) raises `ValueError` reporting the one-based line number.
- AC6: A pytest suite in `test_ini_parser.py` covers AC1 to AC5 and passes.

## Tasks

---

## MUTABLE SECTION
<!-- Update each round with justification for changes -->

### Plan Version: 1 (Updated: Round 0)

#### Plan Evolution Log
<!-- Document any changes to the plan with justification -->
| Round | Change | Reason | Impact on AC |
|-------|--------|--------|--------------|
| 0 | Initial plan | - | - |

#### Active Tasks
<!-- Mainline tasks only: each task must directly advance the current round objective and carry routing metadata -->
| Task | Target AC | Status | Tag | Owner | Notes |
|------|-----------|--------|-----|-------|-------|

### Blocking Side Issues
<!-- Only issues that directly block current mainline progress belong here -->
| Issue | Discovered Round | Blocking AC | Resolution Path |
|-------|-----------------|-------------|-----------------|

### Queued Side Issues
<!-- Non-blocking issues stay queued and must NOT replace the round objective -->
| Issue | Discovered Round | Why Not Blocking | Revisit Trigger |
|-------|-----------------|------------------|-----------------|
| `parse()` returns an empty default section even when no section-less keys were present | 0 | AC3 requires section-less keys to use section `""`, but does not specify whether an empty default section must be emitted; current behavior does not violate any AC | Revisit if downstream users need exact section emission semantics instead of the current always-present default section |

### Completed and Verified
<!-- Only move tasks here after Codex verification -->
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC1-AC5 | Implement `ini_parser.py` | 0 | 0 | Codex reviewed `ini_parser.py`; `.venv/bin/pytest test_ini_parser.py -v` -> 15 passed |
| AC6 | Write `test_ini_parser.py` | 0 | 0 | Codex reviewed `test_ini_parser.py`; 15 tests covering AC1-AC5; all passing |
| AC6 | Run suite and make it pass | 0 | 0 | Codex ran `.venv/bin/pytest test_ini_parser.py -v` -> 15 passed |

### Explicitly Deferred
<!-- Items here require strong justification -->
| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|
