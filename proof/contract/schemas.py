"""Loading of the versioned Proof contract schema documents."""

import json
from pathlib import Path
from typing import Any, Dict

from .schema_validator import schema_issues


_SCHEMA_FILENAMES = {
    "proof-bundle-v0": "proof-bundle-v0.schema.json",
    "verification-profile-v0": "verification-profile-v0.schema.json",
}
_SCHEMA_DIRECTORY = Path(__file__).resolve().parents[1] / "schema"


def load_schema(name: str) -> Dict[str, Any]:
    """Load a fresh copy of one supported versioned schema document."""
    try:
        filename = _SCHEMA_FILENAMES[name]
    except KeyError as error:
        supported = ", ".join(sorted(_SCHEMA_FILENAMES))
        raise ValueError(f"Unsupported Proof schema {name!r}; expected one of: {supported}") from error

    schema = json.loads((_SCHEMA_DIRECTORY / filename).read_text(encoding="utf-8"))
    issues = schema_issues(schema)
    if issues:
        details = "; ".join(
            f"{issue.path}: {issue.message}" for issue in issues
        )
        raise ValueError(f"Invalid bundled Proof schema {name!r}: {details}")
    return schema
