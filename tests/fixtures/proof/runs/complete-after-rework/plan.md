# Normalize a display slug

## Goal

Implement a deterministic display-slug helper for short labels.

## Acceptance Criteria

- `slugify.py` exports `slugify(text)`.
- `slugify("Hello, World!")` returns exactly `"hello-world"`.
- Repeated whitespace and punctuation do not create repeated or edge hyphens.
- `test_slugify.py` covers the specified example and the cleanup behavior.
- The corrected implementation and tests are committed before the final review.

## Constraints

- Use only the Python standard library.
- Keep the change limited to the slug helper and its test.
