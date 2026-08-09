# Code Review Findings

You are in the **Review Phase**. Codex has performed a code review and found issues that need to be addressed.

## Required Re-anchor

Before touching code:
- Re-read the original plan at @.loop/rlcr/2026-08-08_00-53-47/plan.md
- Re-read the goal tracker at @/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/goal-tracker.md
- Refresh the current round contract at @/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/round-1-contract.md

The round contract must preserve a single mainline objective. Code review findings do NOT automatically become the new round objective.

## Review Results

## Codex Review Issues

- [P1] Quote CSV fields before joining — /Users/quiz/loop-dogfood/csv-writer/csv_writer.py:6-8
  When any header or row value contains the delimiter, a double quote, or a newline/CR, hand-joining fields does not round-trip through `csv.reader` (for example, `"x,y"` is parsed as two fields). This violates the required quoting/escaping behavior in `plan.md:10-12`; the writer needs CSV-aware field escaping rather than raw `delimiter.join`.

- [P2] Validate row widths before writing — /Users/quiz/loop-dogfood/csv-writer/csv_writer.py:7-8
  Rows with a different number of values than the header are currently emitted silently, so `write_csv(["a", "b"], [[1]])` returns malformed output instead of raising the `ValueError` with the zero-based row index required by `plan.md:13-14`.

- [P2] Write None values as empty fields — /Users/quiz/loop-dogfood/csv-writer/csv_writer.py:8-8
  For row cells that are `None`, `str(cell)` writes the literal text `None`, but the acceptance criteria require `None` to serialize as an empty field (`plan.md:15`). This changes the round-tripped value from empty to the string `"None"`.

- [P2] Round-trip the required CSV edge cases — /Users/quiz/loop-dogfood/csv-writer/test_csv_writer.py:4-9
  The added tests only cover simple string output, so the required `csv.reader` round-trip cases for delimiter/quotes/CR/LF, `None`, and row-length errors in `plan.md:10-16` can all fail while the suite passes. Add tests that parse the generated text with `csv.reader` and assert the required `ValueError` path.
The implementation does not satisfy the documented CSV round-trip, row-width validation, or None-serialization requirements, and the tests do not cover those acceptance criteria.

Full review comments:

- [P1] Quote CSV fields before joining — /Users/quiz/loop-dogfood/csv-writer/csv_writer.py:6-8
  When any header or row value contains the delimiter, a double quote, or a newline/CR, hand-joining fields does not round-trip through `csv.reader` (for example, `"x,y"` is parsed as two fields). This violates the required quoting/escaping behavior in `plan.md:10-12`; the writer needs CSV-aware field escaping rather than raw `delimiter.join`.

- [P2] Validate row widths before writing — /Users/quiz/loop-dogfood/csv-writer/csv_writer.py:7-8
  Rows with a different number of values than the header are currently emitted silently, so `write_csv(["a", "b"], [[1]])` returns malformed output instead of raising the `ValueError` with the zero-based row index required by `plan.md:13-14`.

- [P2] Write None values as empty fields — /Users/quiz/loop-dogfood/csv-writer/csv_writer.py:8-8
  For row cells that are `None`, `str(cell)` writes the literal text `None`, but the acceptance criteria require `None` to serialize as an empty field (`plan.md:15`). This changes the round-tripped value from empty to the string `"None"`.

- [P2] Round-trip the required CSV edge cases — /Users/quiz/loop-dogfood/csv-writer/test_csv_writer.py:4-9
  The added tests only cover simple string output, so the required `csv.reader` round-trip cases for delimiter/quotes/CR/LF, `None`, and row-length errors in `plan.md:10-16` can all fail while the suite passes. Add tests that parse the generated text with `csv.reader` and assert the required `ValueError` path.

## Issue Classification

Classify each review finding before acting on it:
- **blocking side issue**: prevents the current mainline objective from succeeding safely or prevents review acceptance
- **queued side issue**: valid follow-up, but does not block the current round objective

Queued issues may be documented, but they must NOT take over the round.

## Task Rules

Every task must use one lane tag:
- `[blocking]` for review findings that must be fixed now
- `[queued]` for non-blocking follow-up work

Do not create new `[mainline]` tasks in review phase unless the review proves the previous mainline objective was incomplete.

## Instructions

1. **Refresh the round contract** at `/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/round-1-contract.md`
2. **Address blocking issues first** and keep the mainline objective stable
3. **Focus on fixes only** - do not add new features or make unrelated changes
4. **Commit your changes** after fixing the issues
5. **Write your summary** to: `/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/round-1-summary.md`

## Summary Template

Your summary should include:
- The mainline objective for this round
- Which blocking issues were fixed
- Which issues were reclassified as queued follow-up
- How each fixed issue was resolved
- Any issues that could not be resolved (with explanation)
- Confirmation that `goal-tracker.md` was updated if the blocking/queued issue lists changed
- A Goal Tracker Update Request only if tracker reconciliation still needs Codex help

## Important Notes

- The COMPLETE signal has no effect during the review phase
- You must address the code review findings to proceed
- After you commit and write your summary, Codex will perform another code review
- The loop continues until no `[P0-9]` issues are found

## Task Tag Routing Reminder

Follow the plan's per-task routing tags strictly:
- `coding` task -> Claude executes directly
- `analyze` task -> execute via `/rloop:ask-codex`, then integrate the result
- Keep Goal Tracker Active Tasks columns `Tag` and `Owner` aligned with execution
