"""The single canonical JSON implementation for Proof of Loop."""

import json
from typing import Any


class CanonicalizationError(ValueError):
    """Raised when a value cannot enter a canonical Proof payload."""


def _validate_json_value(value: Any, path: str = "$") -> None:
    """Reject values outside the deliberately small JSON canonicalization subset."""
    if value is None or isinstance(value, (bool, int, str)):
        return
    if isinstance(value, float):
        raise CanonicalizationError(
            f"{path}: floating-point numbers are forbidden in canonical Proof payloads"
        )
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_json_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise CanonicalizationError(f"{path}: object keys must be strings")
            _validate_json_value(item, f"{path}.{key}")
        return
    raise CanonicalizationError(
        f"{path}: unsupported value type {type(value).__name__} in canonical Proof payload"
    )


def canonical_json_bytes(value: Any) -> bytes:
    """Serialize a JSON value using the Proof v0 JCS subset as UTF-8 bytes.

    Keys are sorted by Unicode code point, strings retain non-ASCII characters,
    and compact separators eliminate whitespace. Floats are intentionally rejected
    before serialization to keep identity hashes stable across runtimes.
    """
    _validate_json_value(value)
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
