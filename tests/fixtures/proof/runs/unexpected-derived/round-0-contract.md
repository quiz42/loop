# Round 0 Contract

## IMMUTABLE SECTION
<!-- Can only be modified in Round 0. Read-only after this round. -->

### Mainline Objective

Implement the deterministic greeting module: create `greeting.py` exporting
`greeting()` returning exactly `"hello"`, and `test_greeting.py` verifying it
via `unittest`, then commit both.

### Target ACs

- AC1: `greeting.py` exports `greeting()` returning exactly `"hello"`.
- AC2: `test_greeting.py` verifies `greeting()` using `unittest`.

### Blocking Side Issues In Scope

None identified. No existing code or dependencies conflict with this task.

### Queued Side Issues Out Of Scope

None identified.

### Round Success Criteria

- `greeting.py` exists, exports `greeting()`, and calling it returns exactly `"hello"`.
- `test_greeting.py` exists and uses `unittest` to assert the return value.
- `python -m unittest test_greeting.py` (or equivalent) passes.
- Both files are committed to git with a descriptive commit message.
- No files outside the greeting module and its test are modified.
