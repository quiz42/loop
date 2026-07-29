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
Add a tiny Python greeting module with one independently verifiable behavior.

### Acceptance Criteria
<!-- Each criterion must be independently verifiable -->
<!-- Claude must extract or define these in Round 0 -->

1. AC1: `greeting.py` exports a function `greeting()` that returns exactly the string `"hello"`.
2. AC2: `test_greeting.py` verifies `greeting()` using the `unittest` module.
3. AC3: The implementation and test files are committed to git before review begins.
4. AC4: Only the Python standard library is used (no third-party dependencies).
5. AC5: The change is limited to the greeting module and its test (no unrelated files touched).

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

### Completed and Verified
<!-- Only move tasks here after Codex verification -->
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC1, AC4, AC5 | Implement greeting.py | 0 | 0 | Commit 0dbb224; `greeting.py` defines `greeting()` returning `"hello"`; Codex verified diff is limited to `greeting.py` and `test_greeting.py` |
| AC2 | Write test_greeting.py | 0 | 0 | Commit 0dbb224; `test_greeting.py` asserts `greeting() == "hello"` via unittest |
| AC3 | Run tests and commit | 0 | 0 | Codex reran `python3 -m unittest test_greeting.py -v` -> OK (1 test); commit 0dbb224 |

### Explicitly Deferred
<!-- Items here require strong justification -->
| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|
