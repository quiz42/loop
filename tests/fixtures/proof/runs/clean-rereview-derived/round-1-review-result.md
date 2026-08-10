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
