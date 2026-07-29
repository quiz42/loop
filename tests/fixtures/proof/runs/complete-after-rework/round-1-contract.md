# Round 1 Contract

- Mainline Objective: Keep the current branch aligned with @plan.md while resolving only review findings that block clean acceptance.
- Target ACs: `slugify.py` exports `slugify(text)`; `slugify("Hello, World!") == "hello-world"`; repeated whitespace/punctuation do not create repeated or edge hyphens; `test_slugify.py` covers the specified example and cleanup behavior; corrected implementation and tests committed before final review.
- Blocking Side Issues In Scope:
  - [P1] `slugify.py:6` only replaces literal spaces; does not lowercase or normalize punctuation, so `slugify("Hello, World!")` returns `"Hello,-World!"` instead of `"hello-world"`.
  - [P2] `test_slugify.py:10` only covers the single-space case with uppercase-preserving expectations; missing coverage for the plan's required example and repeated whitespace/punctuation cleanup.
- Queued Side Issues Out of Scope: None identified this round.
- Success Criteria: Code review passes and the current branch still matches the original plan's intended scope.
