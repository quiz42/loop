# Round 1 Contract

- Mainline Objective: Run code review for the current branch and resolve only findings that block clean acceptance (unchanged from Round 0).
- Target ACs: AC-1, AC-2
- Blocking Side Issues In Scope (all four Codex findings map directly to plan.md AC1-AC4, so all are blocking):
  - [P1] Quote/escape CSV fields so output round-trips through `csv.reader` (plan.md AC1).
  - [P2] Raise `ValueError` naming the zero-based row index when a row's length differs from the header's (plan.md AC2).
  - [P2] Serialize `None` cells as an empty field, not the text `None` (plan.md AC3).
  - [P2] Extend tests to round-trip the above cases through `csv.reader`, including the `ValueError` path (plan.md AC4).
- Queued Side Issues Out of Scope: none identified this round.
- Success Criteria: Code review passes with no blocking findings; all four issues above are fixed and covered by tests.
