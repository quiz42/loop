#!/usr/bin/env python3
"""Contract-vector tests for the Proof of Loop foundation."""

import hashlib
import json
import sys
import unittest
from copy import deepcopy
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from proof.contract import (
    CanonicalizationError,
    canonical_json_bytes,
    compute_proof_id,
    compute_run_id,
    load_schema,
    proof_id_payload,
    run_id_payload,
    validate_instance,
)


def load_vectors(filename):
    """Load a committed contract-vector document without depending on the implementation."""
    path = PROJECT_ROOT / "tests" / "fixtures" / "proof" / "contract" / filename
    return json.loads(path.read_text(encoding="utf-8"))["vectors"]


def load_schema_documents():
    """Load the committed positive proof and profile documents."""
    path = PROJECT_ROOT / "tests" / "fixtures" / "proof" / "contract" / "schema-validation-v0.json"
    return json.loads(path.read_text(encoding="utf-8"))


def load_profile(name):
    """Load one committed, versioned Proof verification profile."""
    path = PROJECT_ROOT / "proof" / "profiles" / f"{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def error_keywords(result):
    """Return the keywords reported by the public validation result."""
    return {issue.keyword for issue in result.errors}


class CanonicalizationVectorTests(unittest.TestCase):
    """The canonicalizer produces the committed bytes, not merely an equivalent value."""

    def test_committed_canonicalization_vectors(self):
        vectors = load_vectors("canonicalization-v0.json")

        for vector in vectors:
            with self.subTest(vector=vector["name"]):
                actual = canonical_json_bytes(vector["input"])
                if "canonical_json" in vector:
                    expected = vector["canonical_json"].encode("utf-8")
                else:
                    expected = bytes.fromhex(vector["canonical_utf8_hex"])
                self.assertEqual(actual, expected)
                self.assertEqual(hashlib.sha256(actual).hexdigest(), vector["sha256"])

    def test_floating_point_values_are_rejected_at_every_depth(self):
        for payload in (1.5, {"nested": [0, 1.5]}, {"nan": float("nan")}):
            with self.subTest(payload=repr(payload)):
                with self.assertRaises(CanonicalizationError):
                    canonical_json_bytes(payload)


class RunIdVectorTests(unittest.TestCase):
    """Run identity projects only inherent facts and preserves missing facts as null."""

    def test_committed_run_id_vectors(self):
        for vector in load_vectors("run-id-v0.json"):
            with self.subTest(vector=vector["name"]):
                payload = run_id_payload(vector["facts"])
                self.assertEqual(
                    canonical_json_bytes(payload),
                    vector["canonical_payload"].encode("utf-8"),
                )
                self.assertEqual(compute_run_id(vector["facts"]), vector["run_id"])

    def test_profile_and_round_order_cannot_be_normalized_away(self):
        facts = {
            "base_commit": "base",
            "head_commit": "head",
            "session_timestamp": "2026-07-29T10:11:12Z",
            "terminal_state": "complete",
            "round_indices": [0, 2],
            "profile": "public-v0",
        }
        expected = compute_run_id(facts)
        facts["profile"] = "local-v0"
        self.assertEqual(compute_run_id(facts), expected)
        facts["round_indices"] = [2, 0]
        self.assertNotEqual(compute_run_id(facts), expected)


class ProofIdVectorTests(unittest.TestCase):
    """Bundle identity excludes transport metadata and does not mutate the bundle."""

    def test_committed_proof_id_vectors(self):
        for vector in load_vectors("proof-id-v0.json"):
            with self.subTest(vector=vector["name"]):
                original = deepcopy(vector["bundle"])
                payload = proof_id_payload(vector["bundle"])
                self.assertEqual(
                    canonical_json_bytes(payload),
                    vector["canonical_payload"].encode("utf-8"),
                )
                self.assertEqual(compute_proof_id(vector["bundle"]), vector["proof_id"])
                self.assertEqual(vector["bundle"], original)

    def test_transport_changes_do_not_change_proof_id(self):
        bundle = deepcopy(load_vectors("proof-id-v0.json")[0]["bundle"])
        expected = compute_proof_id(bundle)
        bundle["transport"] = {
            "exported_at": "2030-01-01T00:00:00Z",
            "exporter_host_class": "linux",
            "nested": {"machine": "different"},
        }
        self.assertEqual(compute_proof_id(bundle), expected)

    def test_absent_transport_does_not_change_proof_id(self):
        bundle = deepcopy(load_vectors("proof-id-v0.json")[0]["bundle"])
        expected = compute_proof_id(bundle)
        bundle.pop("transport")
        self.assertEqual(compute_proof_id(bundle), expected)


class PublicProfileTests(unittest.TestCase):
    """The committed public profiles freeze their minimum evidence contract.

    `public-v0` is immutable (ADR-0006): distributed Bundles pin its document
    hash, so its bytes must never change and it must never gain a masking
    licence. `public-v1` is the default revision and carries the masking
    contract; its required evidence set is pinned here so a future edit to
    the default profile is a deliberate revision, not a drive-by.
    """

    _REQUIRED_EVIDENCE = [
        "plan",
        "goal_tracker",
        "state",
        "round_summary",
        "round_review_result",
    ]

    def test_public_v0_is_schema_valid_and_requires_the_frozen_evidence_set(self):
        profile = load_profile("public-v0")
        result = validate_instance(profile, load_schema("verification-profile-v0"))

        self.assertTrue(result.is_valid, result.errors)
        self.assertEqual(profile["required_evidence_kinds"], self._REQUIRED_EVIDENCE)
        self.assertNotIn("mask_on", profile["secret_scan"])
        self.assertNotIn("mask_kinds", profile["secret_scan"])

    def test_public_v1_is_schema_valid_and_pins_the_masking_contract(self):
        profile = load_profile("public-v1")
        result = validate_instance(profile, load_schema("verification-profile-v0"))

        self.assertTrue(result.is_valid, result.errors)
        self.assertEqual(profile["required_evidence_kinds"], self._REQUIRED_EVIDENCE)
        self.assertEqual(profile["secret_scan"]["mask_on"], ["absolute-path"])
        self.assertEqual(profile["secret_scan"]["mask_kinds"], ["round_review_result"])

    def test_every_masked_scan_class_has_an_omit_fallback(self):
        """Masking is never the whole answer for a scan class, so it needs a floor.

        Bytes that are not UTF-8 cannot be rewritten, a substitution leaving a
        match behind must not be published, and one that no longer fits
        `max_item_bytes` cannot be carried. All three fall through to the
        omission rule, so a profile masking a class it cannot omit would
        publish the source with the paths masking exists to remove. The schema
        cannot express a dependency between two lists, so it is asserted here
        for the shipped profiles and enforced in `load_profile` for any other.
        """
        for name in ("local-v0", "public-v0", "public-v1"):
            secret_scan = load_profile(name)["secret_scan"]
            self.assertLessEqual(
                set(secret_scan.get("mask_on", [])),
                set(secret_scan.get("omit_on", [])),
                f"{name} masks a scan class it cannot omit",
            )

    def test_load_profile_refuses_a_masking_licence_with_no_fallback(self):
        from proof.core import ProofError
        from proof.core import load_profile as load_profile_checked

        broken = deepcopy(load_profile("public-v1"))
        broken["secret_scan"]["omit_on"] = []
        with mock.patch("proof.core._default_profile", return_value=broken):
            with self.assertRaises(ProofError) as raised:
                load_profile_checked("public-v1")
        self.assertIn("omit_on", str(raised.exception))


class SchemaValidationTests(unittest.TestCase):
    """Both schemas accept their documented documents and expose actionable violations."""

    def setUp(self):
        documents = load_schema_documents()
        self.bundle = documents["proof_bundle"]
        self.profile = documents["verification_profile"]
        self.bundle_schema = load_schema("proof-bundle-v0")
        self.profile_schema = load_schema("verification-profile-v0")

    def test_positive_documents_are_valid(self):
        self.assertTrue(validate_instance(self.bundle, self.bundle_schema).is_valid)
        self.assertTrue(validate_instance(self.profile, self.profile_schema).is_valid)

    def test_empty_acceptance_criteria_are_readable_legacy_evidence(self):
        bundle = deepcopy(self.bundle)
        bundle["specification"]["acceptance_criteria"] = []
        self.assertTrue(validate_instance(bundle, self.bundle_schema).is_valid)

    def test_explorer_attestation_is_optional_for_legacy_bundles(self):
        legacy = deepcopy(self.bundle)
        legacy.pop("explorer", None)
        self.assertTrue(validate_instance(legacy, self.bundle_schema).is_valid)

        current = deepcopy(legacy)
        current["explorer"] = {
            "assets": {
                "index.html": "sha256:" + "a" * 64,
                "app.js": "sha256:" + "b" * 64,
                "styles.css": "sha256:" + "c" * 64,
            }
        }
        self.assertTrue(validate_instance(current, self.bundle_schema).is_valid)

        missing_asset = deepcopy(current)
        missing_asset["explorer"]["assets"].pop("app.js")
        self.assertIn(
            "required",
            error_keywords(validate_instance(missing_asset, self.bundle_schema)),
        )

        malformed_hash = deepcopy(current)
        malformed_hash["explorer"]["assets"]["styles.css"] = "not-a-sha256"
        self.assertIn(
            "pattern",
            error_keywords(validate_instance(malformed_hash, self.bundle_schema)),
        )

    def test_every_public_field_has_a_description(self):
        for schema in (self.bundle_schema, self.profile_schema):
            for property_schema in walk_public_properties(schema):
                self.assertIsInstance(property_schema.get("description"), str)
                self.assertTrue(property_schema["description"].strip())

    def test_unknown_properties_are_warned_and_retained(self):
        for document, schema in (
            (self.bundle, self.bundle_schema),
            (self.profile, self.profile_schema),
        ):
            with self.subTest(schema=schema["title"]):
                candidate = deepcopy(document)
                candidate["future_extension"] = {"preserved": "yes"}
                result = validate_instance(candidate, schema)
                self.assertTrue(result.is_valid)
                self.assertEqual(candidate["future_extension"], {"preserved": "yes"})
                self.assertTrue(result.warnings)
                self.assertIn("additionalProperties", {issue.keyword for issue in result.warnings})

    def test_floats_are_rejected_even_in_unknown_extensions(self):
        bundle = deepcopy(self.bundle)
        bundle["future_extension"] = {"numeric_value": 1.5}
        result = validate_instance(bundle, self.bundle_schema)
        self.assertFalse(result.is_valid)
        self.assertIn("x-canonical-payload", error_keywords(result))
        self.assertEqual(bundle["future_extension"]["numeric_value"], 1.5)

    def test_bundle_keyword_violations_are_rejected(self):
        cases = [
            ("type", "type", lambda value: value["source"].__setitem__("repo_name", True)),
            ("required proof_id", "required", lambda value: value.pop("proof_id")),
            ("required transport", "required", lambda value: value.pop("transport")),
            ("enum", "enum", lambda value: value["run"].__setitem__("terminal_state", "running")),
            ("const", "const", lambda value: value.__setitem__("schema_version", "proof-bundle-v1")),
            ("items", "type", lambda value: value.__setitem__("evidence", ["not-an-evidence-object"])),
            ("pattern", "pattern", lambda value: value["transport"].__setitem__("exported_at", "tomorrow")),
            ("oneOf", "oneOf", lambda value: value["evidence"][0].__setitem__("omitted_reason", True)),
            ("anyOf", "anyOf", lambda value: value["source"].__setitem__("head_commit", True)),
        ]
        for name, expected_keyword, mutate in cases:
            with self.subTest(case=name):
                bundle = deepcopy(self.bundle)
                mutate(bundle)
                self.assertIn(
                    expected_keyword,
                    error_keywords(validate_instance(bundle, self.bundle_schema)),
                )

    def test_profile_keyword_violations_are_rejected(self):
        cases = [
            ("type", "type", lambda value: value.__setitem__("max_bundle_bytes", True)),
            ("required", "required", lambda value: value.pop("secret_scan")),
            ("enum", "enum", lambda value: value["secret_scan"].__setitem__("fail_on", ["unknown-class"])),
            ("const", "const", lambda value: value.__setitem__("version", "1")),
            ("items", "type", lambda value: value.__setitem__("omit_paths", [False])),
            ("minItems", "minItems", lambda value: value.__setitem__("required_evidence_kinds", [])),
            ("pattern", "pattern", lambda value: value.__setitem__("name", "Public V0")),
            (
                "field redaction enum",
                "enum",
                lambda value: value["field_redactions"][0].__setitem__(
                    "field", "commit.subject"
                ),
            ),
        ]
        for name, expected_keyword, mutate in cases:
            with self.subTest(keyword=name):
                profile = deepcopy(self.profile)
                mutate(profile)
                self.assertIn(
                    expected_keyword,
                    error_keywords(validate_instance(profile, self.profile_schema)),
                )

    def test_additional_properties_false_and_combinators_are_implemented(self):
        closed_schema = {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "additionalProperties": False,
        }
        self.assertIn(
            "additionalProperties",
            error_keywords(validate_instance({"name": "ok", "extra": "no"}, closed_schema)),
        )

        one_of_schema = {
            "oneOf": [
                {"type": "integer"},
                {"type": "boolean"},
            ]
        }
        any_of_schema = {
            "anyOf": [
                {"type": "string", "pattern": "^ready$"},
                {"const": None},
            ]
        }
        self.assertTrue(validate_instance(True, one_of_schema).is_valid)
        overlapping_one_of = {
            "oneOf": [
                {"type": "string"},
                {"pattern": "^ready$"},
            ]
        }
        self.assertIn(
            "oneOf", error_keywords(validate_instance("ready", overlapping_one_of))
        )
        self.assertFalse(validate_instance("no", any_of_schema).is_valid)
        self.assertTrue(validate_instance(None, any_of_schema).is_valid)

    def test_boolean_is_not_an_integer_or_a_matching_numeric_enum(self):
        self.assertIn(
            "type", error_keywords(validate_instance(True, {"type": "integer"}))
        )
        self.assertIn(
            "enum", error_keywords(validate_instance(True, {"enum": [1]}))
        )

    def test_unsupported_schema_keywords_fail_closed_at_every_schema_depth(self):
        cases = [
            (
                "nested minLength",
                {
                    "type": "object",
                    "properties": {"name": {"type": "string", "minLength": 5}},
                },
                {"name": "ab"},
                "$.properties.name",
            ),
            ("reference", {"$ref": "https://loop.local/schema/other.json"}, {}, "$"),
            ("allOf", {"allOf": [{"type": "string"}]}, "value", "$"),
            ("unknown extension", {"x-future-policy": True}, {}, "$"),
        ]
        for name, schema, instance, expected_path in cases:
            with self.subTest(case=name):
                result = validate_instance(instance, schema)
                self.assertFalse(result.is_valid)
                self.assertEqual(
                    [(issue.path, issue.keyword) for issue in result.errors],
                    [(expected_path, "unsupported-schema-keyword")],
                )

    def test_unanchored_patterns_are_rejected_by_the_v0_schema_subset(self):
        result = validate_instance("ready", {"type": "string", "pattern": "ready"})
        self.assertFalse(result.is_valid)
        self.assertEqual(
            [(issue.path, issue.keyword) for issue in result.errors],
            [("$", "unsupported-schema-pattern")],
        )

    def test_invalid_schema_metadata_and_extensions_fail_closed(self):
        cases = [
            (
                "invalid additionalProperties",
                {"type": "object", "additionalProperties": "warn"},
                "schema",
            ),
            (
                "disabled canonical payload",
                {"type": "object", "x-canonical-payload": False},
                "schema",
            ),
            (
                "unknown field policy",
                {"type": "object", "x-unknown-field-policy": "ignore"},
                "schema",
            ),
            (
                "unregistered extension",
                {"type": "object", "x-future-policy": True},
                "unsupported-schema-keyword",
            ),
        ]
        for name, schema, expected_keyword in cases:
            with self.subTest(case=name):
                result = validate_instance({}, schema)
                self.assertFalse(result.is_valid)
                self.assertIn(expected_keyword, error_keywords(result))

    def test_malformed_supported_keyword_values_fail_closed_without_crashing(self):
        cases = [
            ("type", {"type": None}, "value", "schema"),
            ("type member", {"type": ["string", "future"]}, "value", "schema"),
            ("properties", {"type": "object", "properties": None}, {}, "schema"),
            ("required", {"type": "object", "required": None}, {}, "schema"),
            (
                "required scalar",
                {"type": "object", "required": "name"},
                {"name": "ok"},
                "schema",
            ),
            (
                "additionalProperties",
                {"type": "object", "additionalProperties": None},
                {"future": "value"},
                "schema",
            ),
            ("items", {"type": "array", "items": None}, ["value"], "schema"),
            ("minItems", {"type": "array", "minItems": "1"}, [], "schema"),
            ("negative minItems", {"type": "array", "minItems": -1}, [], "schema"),
            (
                "pattern",
                {"type": "string", "pattern": None},
                "value",
                "unsupported-schema-pattern",
            ),
            ("enum", {"enum": None}, "value", "schema"),
            ("enum scalar", {"enum": "value"}, "v", "schema"),
            ("oneOf", {"oneOf": None}, "value", "schema"),
            ("anyOf", {"anyOf": []}, "value", "schema"),
            (
                "nested canonical payload",
                {
                    "type": "object",
                    "properties": {"value": {"x-canonical-payload": True}},
                },
                {"value": 1.5},
                "schema",
            ),
        ]
        for name, schema, instance, expected_keyword in cases:
            with self.subTest(keyword=name):
                result = validate_instance(instance, schema)
                self.assertFalse(result.is_valid)
                self.assertIn(expected_keyword, error_keywords(result))

    def test_profile_evidence_kind_lists_match_the_bundle_contract(self):
        bundle_kinds = self.bundle_schema["properties"]["evidence"]["items"]["properties"]["kind"]["enum"]
        profile_properties = self.profile_schema["properties"]
        self.assertEqual(
            profile_properties["required_evidence_kinds"]["items"]["enum"],
            bundle_kinds,
        )
        self.assertEqual(profile_properties["omit_kinds"]["items"]["enum"], bundle_kinds)

        for field in ("required_evidence_kinds", "omit_kinds"):
            with self.subTest(field=field):
                profile = deepcopy(self.profile)
                profile[field] = ["not-a-real-kind"]
                self.assertIn(
                    "enum", error_keywords(validate_instance(profile, self.profile_schema))
                )

    def test_round_kind_enum_matches_the_deriving_code(self):
        """The schema's round kinds and the code's must not drift apart.

        `round_projection` writes one of these strings into every Bundle and the
        Validator compares against what it re-derives. If the schema admitted a
        kind the code never produces, or refused one it does, the disagreement
        would surface as an unexplained `invalid` on an honest Bundle.
        """
        from proof.core import ROUND_KINDS

        schema_kinds = self.bundle_schema["properties"]["run"]["properties"][
            "rounds"
        ]["items"]["properties"]["kind"]["enum"]
        self.assertEqual(tuple(schema_kinds), ROUND_KINDS)

    def test_anchored_patterns_reject_trailing_newlines(self):
        cases = [
            ("proof_id", lambda value: value.__setitem__("proof_id", value["proof_id"] + "\n")),
            (
                "transport timestamp",
                lambda value: value["transport"].__setitem__(
                    "exported_at", value["transport"]["exported_at"] + "\n"
                ),
            ),
        ]
        for name, mutate in cases:
            with self.subTest(case=name):
                bundle = deepcopy(self.bundle)
                mutate(bundle)
                self.assertIn(
                    "pattern", error_keywords(validate_instance(bundle, self.bundle_schema))
                )

    def test_invalid_array_item_reports_one_leaf_diagnostic(self):
        bundle = deepcopy(self.bundle)
        bundle["evidence"] = ["not-an-evidence-object"]
        result = validate_instance(bundle, self.bundle_schema)
        self.assertEqual(
            [(issue.path, issue.keyword) for issue in result.errors],
            [("$.evidence[0]", "type")],
        )


def walk_public_properties(schema):
    """Yield every property schema, including properties nested in combinators and items."""
    if not isinstance(schema, dict):
        return
    for property_schema in schema.get("properties", {}).values():
        yield property_schema
        yield from walk_public_properties(property_schema)
    for branch_name in ("oneOf", "anyOf"):
        for branch in schema.get(branch_name, []):
            yield from walk_public_properties(branch)
    items = schema.get("items")
    if isinstance(items, dict):
        yield from walk_public_properties(items)


if __name__ == "__main__":
    unittest.main(verbosity=2)
