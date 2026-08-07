# Round 0 Contract

## Mainline Objective

Implement `ini_parser.py` (parse function + DuplicateKeyError) and a passing
`test_ini_parser.py` pytest suite covering AC1-AC5, satisfying AC6.

## Target ACs

- AC1: `parse(text: str) -> dict` behavior (sections/keys, stripping rules)
- AC6: pytest suite exists and passes, covering AC1-AC5

(All of AC1-AC5 are implemented this round since the whole module is small
and each criterion maps to a small, indivisible piece of parser logic; AC6
requires the suite to exercise all of them.)

## Blocking Side Issues In Scope

None identified yet.

## Queued Side Issues Out Of Scope

None identified yet.

## Round Success Criteria

- `ini_parser.py` exists with `parse()` and `DuplicateKeyError` implementing
  AC1-AC5.
- `test_ini_parser.py` exists with tests covering AC1-AC5.
- `pytest` run passes with no failures.
- Changes committed with a descriptive message.
