# Skip Implementation Mode - Code Review Loop

This RLCR loop was started with `--skip-impl` flag.

**Mode**: Code Review Only (skipping implementation phase)
**Base Branch**: main
**Current Branch**: work

## What This Means

The loop will automatically run `codex review` on your changes when you try to exit.
If issues are found (marked with [P0-9] priority), you'll need to fix them before the loop ends.
Do not try to execute anything to trigger the review - just stop and it will run automatically.

Before requesting review, read:
- @.loop/rlcr/2026-08-08_00-53-47/plan.md
- @/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/goal-tracker.md
- @/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/round-0-contract.md

## Your Task

1. Review your current work
2. When ready, try to exit - Codex will review your code
3. Fix any issues Codex finds
4. Repeat until no issues remain
5. Enter finalize phase for code simplification

## Review Objective

Use the round contract as the current anchor:
- Keep one stable mainline objective and do not let it drift
- Treat review findings as `[blocking]` only if they block review acceptance
- Record non-blocking follow-up as `[queued]`
- Do not let queued work take over the round

There is no explicit implementation plan for this loop, so the review-only contract is the primary anchor.


Keep @/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/round-0-contract.md updated if the blocking/queued split changes materially during review iterations.

When you're ready for review, write a brief summary of your changes and try to exit (do not try to execute anything, just stop).

Write your summary to: @/Users/quiz/loop-dogfood/csv-writer/.loop/rlcr/2026-08-08_00-53-47/round-0-summary.md

