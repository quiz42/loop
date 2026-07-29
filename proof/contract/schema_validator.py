"""A deliberately small, dependency-free JSON Schema subset validator."""

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Union


_SUPPORTED_SCHEMA_KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "title",
        "description",
        "type",
        "required",
        "properties",
        "additionalProperties",
        "enum",
        "const",
        "items",
        "minItems",
        "pattern",
        "oneOf",
        "anyOf",
        "x-canonical-payload",
        "x-unknown-field-policy",
    }
)
_JSON_SCHEMA_TYPES = frozenset(
    {"array", "boolean", "integer", "null", "number", "object", "string"}
)
_STRING_SCHEMA_ANNOTATIONS = ("$schema", "$id", "title", "description")


@dataclass(frozen=True)
class ValidationIssue:
    """One actionable schema error or forward-compatibility warning."""

    path: str
    keyword: str
    message: str


@dataclass
class ValidationResult:
    """Validation diagnostics that never modify the document under inspection."""

    errors: List[ValidationIssue] = field(default_factory=list)
    warnings: List[ValidationIssue] = field(default_factory=list)

    @property
    def is_valid(self) -> bool:
        """Return whether the document has no schema errors."""
        return not self.errors


def validate_instance(instance: Any, schema: Dict[str, Any]) -> ValidationResult:
    """Validate a JSON value against the Proof v0 JSON Schema subset.

    The supported keywords are ``type``, ``required``, ``properties``,
    ``additionalProperties``, ``enum``, ``const``, ``items``, ``minItems``,
    ``pattern``, ``oneOf``, and ``anyOf``. Proof schemas additionally mark a
    canonical payload, which rejects floats recursively before hashing can drift.
    """
    result = ValidationResult()
    result.errors.extend(schema_issues(schema))
    if result.errors:
        return result

    if schema.get("x-canonical-payload") is True:
        _reject_floats(instance, "$", result)

    _validate(instance, schema, "$", result, schema.get("x-unknown-field-policy"))
    return result


def schema_issues(schema: Any) -> List[ValidationIssue]:
    """Return fail-closed diagnostics for unsupported Proof schema constructs."""
    issues: List[ValidationIssue] = []
    _collect_schema_issues(schema, "$", issues)
    return issues


def _collect_schema_issues(
    schema: Any, path: str, issues: List[ValidationIssue]
) -> None:
    """Walk schema positions without confusing object property names for keywords."""
    if not isinstance(schema, dict):
        issues.append(ValidationIssue(path, "schema", "A subschema must be an object."))
        return

    for keyword in schema:
        if keyword not in _SUPPORTED_SCHEMA_KEYWORDS:
            issues.append(
                ValidationIssue(
                    path,
                    "unsupported-schema-keyword",
                    f"Unsupported Proof schema keyword {keyword!r}.",
                )
            )

    _collect_keyword_value_issues(schema, path, issues)
    _collect_extension_issues(schema, path, issues)
    if "pattern" in schema:
        _collect_pattern_issues(schema["pattern"], path, issues)
    _collect_property_schemas(schema, path, issues)
    if "items" in schema:
        _collect_child_schema(schema["items"], f"{path}.items", issues)

    if "additionalProperties" in schema:
        additional_properties = schema["additionalProperties"]
        if isinstance(additional_properties, dict):
            _collect_schema_issues(
                additional_properties, f"{path}.additionalProperties", issues
            )
        elif not isinstance(additional_properties, bool):
            issues.append(
                ValidationIssue(
                    path,
                    "schema",
                    "Schema additionalProperties must be a boolean or a subschema.",
                )
            )

    for keyword in ("oneOf", "anyOf"):
        if keyword not in schema:
            continue
        branches = schema[keyword]
        if not isinstance(branches, list) or not branches:
            issues.append(
                ValidationIssue(
                    path, "schema", f"Schema {keyword} must be a non-empty array."
                )
            )
            continue
        for index, branch in enumerate(branches):
            _collect_schema_issues(branch, f"{path}.{keyword}[{index}]", issues)


def _collect_keyword_value_issues(
    schema: Dict[str, Any], path: str, issues: List[ValidationIssue]
) -> None:
    """Reject malformed values for implemented keywords before validation runs."""
    for keyword in _STRING_SCHEMA_ANNOTATIONS:
        if keyword in schema and not isinstance(schema[keyword], str):
            issues.append(
                ValidationIssue(path, "schema", f"Schema {keyword} must be a string.")
            )

    if "type" in schema and not _is_valid_type_declaration(schema["type"]):
        issues.append(
            ValidationIssue(
                path,
                "schema",
                "Schema type must be a supported JSON type or a non-empty array of them.",
            )
        )

    if "required" in schema:
        required = schema["required"]
        if (
            not isinstance(required, list)
            or not all(isinstance(property_name, str) for property_name in required)
            or len(set(required)) != len(required)
        ):
            issues.append(
                ValidationIssue(
                    path,
                    "schema",
                    "Schema required must be an array of unique property names.",
                )
            )

    if "enum" in schema and (
        not isinstance(schema["enum"], list) or not schema["enum"]
    ):
        issues.append(
            ValidationIssue(path, "schema", "Schema enum must be a non-empty array.")
        )

    if "minItems" in schema:
        min_items = schema["minItems"]
        if (
            not isinstance(min_items, int)
            or isinstance(min_items, bool)
            or min_items < 0
        ):
            issues.append(
                ValidationIssue(
                    path,
                    "schema",
                    "Schema minItems must be a non-negative integer.",
                )
            )


def _is_valid_type_declaration(value: Any) -> bool:
    """Return whether a ``type`` value is usable by ``_matches_type``."""
    if isinstance(value, str):
        return value in _JSON_SCHEMA_TYPES
    if not isinstance(value, list) or not value:
        return False
    return all(
        isinstance(item, str) and item in _JSON_SCHEMA_TYPES for item in value
    ) and len(set(value)) == len(value)


def _collect_extension_issues(
    schema: Dict[str, Any], path: str, issues: List[ValidationIssue]
) -> None:
    """Validate the two registered Proof extensions before they affect behavior."""
    if "x-canonical-payload" in schema:
        if schema["x-canonical-payload"] is not True:
            issues.append(
                ValidationIssue(
                    path,
                    "schema",
                    "x-canonical-payload must be true when declared.",
                )
            )
        elif path != "$":
            issues.append(
                ValidationIssue(
                    path,
                    "schema",
                    "x-canonical-payload may be declared only on a root Proof schema.",
                )
            )
    if (
        "x-unknown-field-policy" in schema
        and schema["x-unknown-field-policy"] != "warn"
    ):
        issues.append(
            ValidationIssue(
                path,
                "schema",
                "x-unknown-field-policy must be 'warn' when declared.",
            )
        )


def _collect_property_schemas(
    schema: Dict[str, Any], path: str, issues: List[ValidationIssue]
) -> None:
    """Walk schema values below ``properties`` while leaving property names opaque."""
    if "properties" not in schema:
        return
    properties = schema["properties"]
    if not isinstance(properties, dict):
        issues.append(ValidationIssue(path, "schema", "Schema properties must be an object."))
        return
    for property_name, property_schema in properties.items():
        _collect_schema_issues(
            property_schema, f"{path}.properties.{property_name}", issues
        )


def _collect_pattern_issues(
    pattern: Any, path: str, issues: List[ValidationIssue]
) -> None:
    """Restrict v0 patterns to the anchored complete-value subset we implement."""
    if not isinstance(pattern, str) or not pattern.startswith("^") or not pattern.endswith("$"):
        issues.append(
            ValidationIssue(
                path,
                "unsupported-schema-pattern",
                "Proof v0 patterns must be anchored complete-value expressions.",
            )
        )
        return
    try:
        re.compile(pattern)
    except re.error as error:
        issues.append(
            ValidationIssue(path, "schema", f"Invalid schema pattern: {error}.")
        )


def _collect_child_schema(
    child: Any, path: str, issues: List[ValidationIssue]
) -> None:
    """Walk an optional schema-valued keyword used by the supported subset."""
    _collect_schema_issues(child, path, issues)


def _reject_floats(value: Any, path: str, result: ValidationResult) -> None:
    """Report every float, including values hidden in forward-compatible fields."""
    if isinstance(value, float):
        result.errors.append(
            ValidationIssue(
                path,
                "x-canonical-payload",
                "Floating-point numbers are forbidden in canonical Proof payloads.",
            )
        )
        return
    if isinstance(value, dict):
        for key, nested in value.items():
            _reject_floats(nested, _property_path(path, key), result)
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            _reject_floats(nested, f"{path}[{index}]", result)


def _validate(
    instance: Any,
    schema: Dict[str, Any],
    path: str,
    result: ValidationResult,
    inherited_unknown_policy: Optional[str],
) -> None:
    """Apply the supported schema keywords at one document location."""
    if not isinstance(schema, dict):
        result.errors.append(
            ValidationIssue(path, "schema", "A subschema must be an object.")
        )
        return

    unknown_policy = schema.get("x-unknown-field-policy", inherited_unknown_policy)
    _validate_combinators(instance, schema, path, result, unknown_policy)

    expected_type = schema.get("type")
    if expected_type is not None and not _matches_type(instance, expected_type):
        result.errors.append(
            ValidationIssue(
                path,
                "type",
                f"Expected {_type_label(expected_type)}, got {_instance_type(instance)}.",
            )
        )
        return

    if "const" in schema and not _json_equal(instance, schema["const"]):
        result.errors.append(
            ValidationIssue(path, "const", "Value does not equal the required constant.")
        )

    if "enum" in schema and not any(
        _json_equal(instance, option) for option in schema["enum"]
    ):
        result.errors.append(
            ValidationIssue(path, "enum", "Value is not one of the permitted values.")
        )

    if "pattern" in schema and isinstance(instance, str):
        try:
            matches = re.fullmatch(schema["pattern"], instance)
        except re.error as error:
            result.errors.append(
                ValidationIssue(path, "pattern", f"Invalid schema pattern: {error}.")
            )
        else:
            if matches is None:
                result.errors.append(
                    ValidationIssue(path, "pattern", "String does not match the required pattern.")
                )

    if isinstance(instance, list):
        _validate_array(instance, schema, path, result, unknown_policy)
    if isinstance(instance, dict):
        _validate_object(instance, schema, path, result, unknown_policy)


def _validate_combinators(
    instance: Any,
    schema: Dict[str, Any],
    path: str,
    result: ValidationResult,
    unknown_policy: Optional[str],
) -> None:
    """Apply limited ``oneOf`` and ``anyOf`` composition with useful diagnostics."""
    for keyword, exact_count in (("oneOf", 1), ("anyOf", None)):
        branches = schema.get(keyword)
        if branches is None:
            continue
        if not isinstance(branches, list):
            result.errors.append(
                ValidationIssue(path, keyword, f"Schema {keyword} must be an array.")
            )
            continue

        matches = []
        for branch in branches:
            branch_result = ValidationResult()
            _validate(instance, branch, path, branch_result, unknown_policy)
            if branch_result.is_valid:
                matches.append(branch_result)

        if exact_count is not None:
            if len(matches) != exact_count:
                result.errors.append(
                    ValidationIssue(
                        path,
                        keyword,
                        f"Value must match exactly one {keyword} branch; matched {len(matches)}.",
                    )
                )
            else:
                result.warnings.extend(matches[0].warnings)
        elif not matches:
            result.errors.append(
                ValidationIssue(path, keyword, "Value does not match any permitted branch.")
            )
        else:
            result.warnings.extend(matches[0].warnings)


def _validate_array(
    instance: List[Any],
    schema: Dict[str, Any],
    path: str,
    result: ValidationResult,
    unknown_policy: Optional[str],
) -> None:
    """Validate array length and homogeneous items when specified."""
    min_items = schema.get("minItems")
    if min_items is not None and len(instance) < min_items:
        result.errors.append(
            ValidationIssue(path, "minItems", f"Expected at least {min_items} items.")
        )

    item_schema = schema.get("items")
    if item_schema is None:
        return
    for index, item in enumerate(instance):
        item_result = ValidationResult()
        _validate(item, item_schema, f"{path}[{index}]", item_result, unknown_policy)
        result.errors.extend(item_result.errors)
        result.warnings.extend(item_result.warnings)


def _validate_object(
    instance: Dict[str, Any],
    schema: Dict[str, Any],
    path: str,
    result: ValidationResult,
    unknown_policy: Optional[str],
) -> None:
    """Validate object fields while preserving and optionally warning about extras."""
    required = schema.get("required", [])
    for property_name in required:
        if property_name not in instance:
            result.errors.append(
                ValidationIssue(
                    path,
                    "required",
                    f"Missing required property {property_name!r}.",
                )
            )

    properties = schema.get("properties", {})
    for property_name, property_schema in properties.items():
        if property_name in instance:
            _validate(
                instance[property_name],
                property_schema,
                _property_path(path, property_name),
                result,
                unknown_policy,
            )

    additional_properties: Union[bool, Dict[str, Any]] = schema.get(
        "additionalProperties", True
    )
    for property_name, value in instance.items():
        if property_name in properties:
            continue
        property_path = _property_path(path, property_name)
        if additional_properties is False:
            result.errors.append(
                ValidationIssue(
                    property_path,
                    "additionalProperties",
                    "Unknown property is not permitted by this schema.",
                )
            )
        elif isinstance(additional_properties, dict):
            _validate(value, additional_properties, property_path, result, unknown_policy)
        elif unknown_policy == "warn":
            result.warnings.append(
                ValidationIssue(
                    property_path,
                    "additionalProperties",
                    "Unknown property is retained for forward compatibility.",
                )
            )


def _matches_type(instance: Any, expected_type: Any) -> bool:
    """Match JSON types precisely, including Python's bool-versus-int edge case."""
    if isinstance(expected_type, list):
        return any(_matches_type(instance, candidate) for candidate in expected_type)
    if expected_type == "null":
        return instance is None
    if expected_type == "boolean":
        return isinstance(instance, bool)
    if expected_type == "object":
        return isinstance(instance, dict)
    if expected_type == "array":
        return isinstance(instance, list)
    if expected_type == "string":
        return isinstance(instance, str)
    if expected_type == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if expected_type == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    return False


def _json_equal(left: Any, right: Any) -> bool:
    """Compare JSON values without treating true and 1 as equivalent."""
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left is right
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(
            _json_equal(left_item, right_item) for left_item, right_item in zip(left, right)
        )
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(
            _json_equal(left[key], right[key]) for key in left
        )
    return left == right


def _property_path(path: str, property_name: Any) -> str:
    """Produce an unambiguous, human-readable property path."""
    if isinstance(property_name, str) and property_name.isidentifier():
        return f"{path}.{property_name}"
    return f"{path}[{property_name!r}]"


def _type_label(expected_type: Any) -> str:
    """Format one expected schema type for a diagnostic."""
    if isinstance(expected_type, list):
        return " or ".join(str(candidate) for candidate in expected_type)
    return str(expected_type)


def _instance_type(instance: Any) -> str:
    """Name the JSON type supplied by a caller."""
    if instance is None:
        return "null"
    if isinstance(instance, bool):
        return "boolean"
    if isinstance(instance, int):
        return "integer"
    if isinstance(instance, float):
        return "number"
    if isinstance(instance, str):
        return "string"
    if isinstance(instance, list):
        return "array"
    if isinstance(instance, dict):
        return "object"
    return type(instance).__name__
