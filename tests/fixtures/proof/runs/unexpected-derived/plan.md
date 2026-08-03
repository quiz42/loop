# Add a deterministic greeting

## Goal

Add a tiny Python greeting module with one independently verifiable behavior.

## Acceptance Criteria

- `greeting.py` exports `greeting()` and it returns exactly `"hello"`.
- `test_greeting.py` verifies the public function through `unittest`.
- The implementation and test are committed before review.

## Constraints

- Use only the Python standard library.
- Keep the change limited to the greeting module and its test.
