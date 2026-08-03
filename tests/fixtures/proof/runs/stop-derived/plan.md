# Parse an enablement flag

## Goal

Implement a deterministic parser for a human-supplied enablement flag.

## Acceptance Criteria

- `flag_parser.py` exports `is_enabled(value)`.
- `"yes"`, `"YES"`, and surrounding whitespace are accepted as enabled.
- `"no"`, `"NO"`, and surrounding whitespace are accepted as disabled.
- Other values raise `ValueError` rather than silently becoming disabled.
- `test_flag_parser.py` covers every stated behavior.

## Constraints

- Use only the Python standard library.
- Keep the change limited to the parser and its test.
