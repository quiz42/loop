"""Stable identities for Proof Bundles and their source Loop Runs."""

import hashlib
from collections.abc import Mapping
from typing import Any, Dict

from .canonical import canonical_json_bytes


RUN_ID_FACT_KEYS = (
    "base_commit",
    "head_commit",
    "session_timestamp",
    "terminal_state",
    "round_indices",
)


def run_id_payload(facts: Mapping[str, Any]) -> Dict[str, Any]:
    """Return the exact, profile-independent v0 Run identity projection.

    Each fact is included even when absent from ``facts``. That makes legacy
    Run identifiers deterministic by canonicalizing missing facts as JSON null.
    ``round_indices`` are the supplied zero-based round ordinals; this layer
    deliberately does not infer them from source artifact filenames.
    """
    if not isinstance(facts, Mapping):
        raise TypeError("Run facts must be a mapping")

    payload = {"algo": "run-id-v0"}
    for key in RUN_ID_FACT_KEYS:
        payload[key] = facts.get(key)
    return payload


def compute_run_id(facts: Mapping[str, Any]) -> str:
    """Compute the v0 SHA-256 identifier for one Loop Run's inherent facts."""
    return "sha256:" + hashlib.sha256(canonical_json_bytes(run_id_payload(facts))).hexdigest()


def proof_id_payload(bundle: Mapping[str, Any]) -> Dict[str, Any]:
    """Return the v0 Bundle identity payload without mutable transport metadata."""
    if not isinstance(bundle, Mapping):
        raise TypeError("Proof Bundle must be a mapping")

    payload = dict(bundle)
    payload.pop("proof_id", None)
    payload.pop("transport", None)
    return payload


def compute_proof_id(bundle: Mapping[str, Any]) -> str:
    """Compute the v0 SHA-256 identifier for a Bundle's canonical payload."""
    return "sha256:" + hashlib.sha256(canonical_json_bytes(proof_id_payload(bundle))).hexdigest()
