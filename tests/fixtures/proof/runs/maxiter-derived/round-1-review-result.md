- [P1] Normalize known values and reject invalid flags — /Users/quiz/conductor/workspaces/loop/philadelphia/.context/fixture-runs/cancel-after-review/flag_parser.py:6-6
  For inputs required by the plan such as `"YES"`, `" yes "`, and `" no "`, this exact string comparison returns the wrong result, and for any other value such as `"maybe"` it silently returns `False` instead of raising `ValueError`. This leaves most of the accepted flag formats and the invalid-input behavior unimplemented.
The parser only recognizes the exact lowercase string "yes" and silently treats all other inputs as disabled, which violates multiple acceptance criteria. The tests also do not exercise the required cases, so the behavioral gaps are currently unguarded.

Review comment:

- [P1] Normalize known values and reject invalid flags — /Users/quiz/conductor/workspaces/loop/philadelphia/.context/fixture-runs/cancel-after-review/flag_parser.py:6-6
  For inputs required by the plan such as `"YES"`, `" yes "`, and `" no "`, this exact string comparison returns the wrong result, and for any other value such as `"maybe"` it silently returns `False` instead of raising `ValueError`. This leaves most of the accepted flag formats and the invalid-input behavior unimplemented.
