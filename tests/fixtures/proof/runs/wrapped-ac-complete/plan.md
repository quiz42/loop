# Plan: ini-parser

## Goal

Provide a dependency-free Python module `ini_parser.py` that reads a minimal
INI configuration format into ordinary dictionaries, plus a pytest suite.

## Acceptance Criteria

- AC1: `parse(text: str) -> dict` returns a mapping of section name to a
  mapping of key to value. Keys and section names are stripped of surrounding
  whitespace; values keep interior whitespace but lose surrounding whitespace.
- AC2: Lines whose first non-whitespace character is `#` or `;` are comments
  and are ignored. A `#` or `;` inside a value is part of the value, not the
  start of a comment.
- AC3: A key that appears before any section header belongs to the section
  named by the empty string.
- AC4: A duplicate key inside one section raises `DuplicateKeyError`, a
  subclass of `ValueError`, naming the section and the key. A duplicate
  section header is not an error: its keys merge into the existing section.
- AC5: A malformed line (no `=` and not a comment, blank line, or section
  header) raises `ValueError` reporting the one-based line number.
- AC6: A pytest suite in `test_ini_parser.py` covers AC1 to AC5 and passes.

## Tasks

- [coding] Implement `ini_parser.py`.
- [coding] Write `test_ini_parser.py` covering AC1 to AC6.
- [coding] Run the suite and make it pass.

## Out of Scope

- Interpolation, includes, and type coercion.
- Writing INI files back out.
