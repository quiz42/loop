#!/usr/bin/env python3
"""Contract-vector tests for the Proof of Loop foundation."""

import hashlib
import json
import sys
import unittest
from copy import deepcopy
from pathlib import Path


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
                self.assertEqual(actual, vector["canonical_json"].encode("utf-8"))
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
            ("items", "items", lambda value: value.__setitem__("evidence", ["not-an-evidence-object"])),
            ("minItems", "minItems", lambda value: value["specification"].__setitem__("acceptance_criteria", [])),
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
            ("type", lambda value: value.__setitem__("max_bundle_bytes", True)),
            ("required", lambda value: value.pop("secret_scan")),
            ("enum", lambda value: value["secret_scan"].__setitem__("fail_on", ["unknown-class"])),
            ("const", lambda value: value.__setitem__("version", "1")),
            ("items", lambda value: value.__setitem__("omit_paths", [False])),
            ("minItems", lambda value: value.__setitem__("required_evidence_kinds", [])),
            ("pattern", lambda value: value.__setitem__("name", "Public V0")),
        ]
        for keyword, mutate in cases:
            with self.subTest(keyword=keyword):
                profile = deepcopy(self.profile)
                mutate(profile)
                self.assertIn(keyword, error_keywords(validate_instance(profile, self.profile_schema)))

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
