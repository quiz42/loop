Read and execute below with ultrathink

## Goal Tracker Setup (REQUIRED FIRST STEP)

Before starting implementation, you MUST initialize the Goal Tracker:

1. Read @/Users/quiz/loop-dogfood/ini-parser/.loop/rlcr/2026-08-08_00-14-24/goal-tracker.md
2. If the "Ultimate Goal" section says "[To be extracted...]", extract a clear goal statement from the plan
3. If the "Acceptance Criteria" section says "[To be defined...]", define 3-7 specific, testable criteria
4. Populate the "Active Tasks" table with MAINLINE tasks from the plan, mapping each to an AC and filling Tag/Owner
5. Record any already-known side issues in either "Blocking Side Issues" or "Queued Side Issues"
6. Write the updated goal-tracker.md

## Round Contract Setup (REQUIRED BEFORE CODING)

Before starting implementation, create @/Users/quiz/loop-dogfood/ini-parser/.loop/rlcr/2026-08-08_00-14-24/round-0-contract.md with:

1. **One mainline objective** for this round
2. **Target ACs** (1-2 ACs only)
3. **Blocking side issues in scope** for this round
4. **Queued side issues out of scope** for this round
5. **Round success criteria**

Use this contract to keep the round focused. Do NOT let non-blocking bugs or cleanup work replace the mainline objective.

**IMPORTANT**: The IMMUTABLE SECTION can only be modified in Round 0. After this round, it becomes read-only.

---

## Implementation Plan

For all tasks that need to be completed, please use the Task system (TaskCreate, TaskUpdate, TaskList).

Every task MUST start with exactly one lane tag:
- `[mainline]` for plan-derived work that directly advances the round objective
- `[blocking]` for issues that prevent the mainline objective from succeeding safely
- `[queued]` for non-blocking bugs, cleanup, or follow-up work

Rules:
- `[mainline]` tasks are the primary success condition for the round
- `[blocking]` tasks may be resolved in the round only if they truly block mainline progress
- `[queued]` tasks must NOT become the round objective and do NOT need to be cleared before moving on
- If a new issue is not blocking the current objective, tag it `[queued]` and keep moving on the mainline

## Task Tag Routing (MUST FOLLOW)

Each task must have one routing tag from the plan: `coding` or `analyze`.

- Tag `coding`: Claude executes the task directly.
- Tag `analyze`: Claude must execute via `/rloop:ask-codex`, then integrate Codex output.
- Keep Goal Tracker "Active Tasks" columns **Tag** and **Owner** aligned with execution (`coding -> claude`, `analyze -> codex`).
- If a task has no explicit tag, default to `coding` (Claude executes directly).

# Plan: ini-parser

## Goal

Provide a dependency-free Python module `ini_parser.py` that reads a minimal
INI configuration format into ordinary dictionaries, plus a pytest suite.

## Acceptance Criteria

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

- [coding] Implement `ini_parser.py`.
- [coding] Write `test_ini_parser.py` covering AC1 to AC6.
- [coding] Run the suite and make it pass.

## Out of Scope

- Interpolation, includes, and type coercion.
- Writing INI files back out.

---

## BitLesson Selection (REQUIRED FOR EACH TASK)

Before executing each task or sub-task, you MUST:

1. Read @/Users/quiz/loop-dogfood/ini-parser/.loop/bitlesson.md
2. Run `bitlesson-selector` for each task/sub-task to select relevant lesson IDs
3. Follow the selected lesson IDs (or `NONE`) during implementation

Include a `## BitLesson Delta` section in your summary with:
- Action: none|add|update
- Lesson ID(s): NONE or comma-separated IDs
- Notes: what changed and why (required if action is add or update)

Reference: @/Users/quiz/loop-dogfood/ini-parser/.loop/bitlesson.md

---

## Goal Tracker Rules

Throughout your work, you MUST maintain the Goal Tracker:

1. **Before starting a round**: Re-anchor on the original plan and current round contract
2. **Before starting a task**: Mark the relevant mainline task as "in_progress" in Active Tasks
   - Confirm Tag/Owner routing is correct before execution
3. **Active Tasks** are MAINLINE tasks only - side issues do not belong there
4. **Blocking Side Issues** are reserved for issues that truly stop mainline progress
5. **Queued Side Issues** are non-blocking and must not take over the round
6. **After completing a mainline task**: Move it to "Completed and Verified" with evidence (but mark as "pending verification")
7. **If you discover the plan has errors**:
   - Do NOT silently change direction
   - Add entry to "Plan Evolution Log" with justification
   - Explain how the change still serves the Ultimate Goal
8. **If you need to defer a task**:
   - Move it to "Explicitly Deferred" section
   - Provide strong justification
   - Explain impact on Acceptance Criteria
9. **If you discover new issues**:
   - Add to "Blocking Side Issues" only if mainline progress is blocked
   - Otherwise add to "Queued Side Issues" or keep them as `[queued]` tasks/backlog

---

Note: You MUST NOT try to exit `start-rlcr-loop` loop by lying or edit loop state file or try to execute `cancel-rlcr-loop`

After completing the work, please:
0. If you have access to the `code-simplifier` agent, use it to review and optimize the code you just wrote
1. Finalize @/Users/quiz/loop-dogfood/ini-parser/.loop/rlcr/2026-08-08_00-14-24/goal-tracker.md (this is Round 0, so you are initializing it - see "Goal Tracker Setup" above)
2. Write your round contract into @/Users/quiz/loop-dogfood/ini-parser/.loop/rlcr/2026-08-08_00-14-24/round-0-contract.md
3. Commit your changes with a descriptive commit message
4. Write your work summary into @/Users/quiz/loop-dogfood/ini-parser/.loop/rlcr/2026-08-08_00-14-24/round-0-summary.md
