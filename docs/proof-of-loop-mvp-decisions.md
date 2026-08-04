# Proof of Loop MVP: Design Decision Appendix

> Version: v1.1
> Date: 2026-07-26
> Baseline: [`proof-of-loop-mvp-design.md`](proof-of-loop-mvp-design.md) Draft v0.1 and [`repository-research.md`](repository-research.md)
> This document records the decisions confirmed during an item-by-item design interview. Wherever it diverges from Draft v0.1, this document governs. Term definitions are governed by [`CONTEXT.md`](../CONTEXT.md) at the repository root.

## 1. Product Boundary

### D1. Local-first + static sharing (resolves the open question in Draft §16)

The MVP is strictly limited to locally generated, offline-viewable, statically shareable output: no hosting, no accounts, no backend service. See [ADR-0001](adr/0001-local-first-static-proof-distribution.md).

### D2. Only Runs that have reached a Terminal State can be exported

`loop proof export` accepts only Runs that already have a terminal state file (`complete|stop|cancel|maxiter|unexpected`-`state.md`). A Run holding only `state.md` — including `finalize-state.md`, which is the active state of the Finalize phase rather than a terminal state — is always refused, with an error explaining that the Run has not finished. This eliminates the risk of reading state that is being written concurrently (AC-8); snapshot mode is left to the future. Draft §4's "complete is not a precondition for export" still holds — it means all five terminal states can be exported, not that active Runs can be.

### D3. Terminal State becomes a formal term

A new entry (see CONTEXT.md) enumerates the five terminal values and states explicitly that Terminal State is not a Delivery Verdict — a `complete` terminal state does not amount to an `accept` conclusion.

## 2. Evidence and Identity Model

### D4. Evidence Item identity = source path + content hash

Not a pure content hash. The path (relative to the Run directory) distinguishes *which position within the Run* an item occupies, and the hash detects whether that file has been tampered with. A pure hash would collide two files whose contents happen to be identical (such as identical summaries from two rounds) onto the same ID, breaking the Timeline view.

### D5. The required AC set can be adjusted through a recorded replan

An Acceptance Criterion's own definition is immutable (inheriting the Goal Tracker's immutable-section principle), but *whether it counts toward the required set for an accept decision* can change along with a legitimate replan event, such as a Goal Tracker deferral. Removing a criterion from the required set must cite the specific replan evidence (which round's evolution record); it is never a silent exemption, and the removed criterion remains visible in the Bundle and the UI, marked as deferred. This guards against both extremes at once: a required AC that deadlocks accept forever, and quietly withdrawing a hard AC to manufacture an accept.

### D6. Finding lifecycle transition rules

- `open`: no fix has been attempted yet (waiting for the next round);
- `unverifiable`: a fix was attempted, but the re-review evidence is missing or unparseable (for example, empty `codex review` output) — semantically distinct from `open`, and it implies a different action for the maintainer ("wait for the next round" versus "someone needs to read the diff");
- `resolved` / `waived`: reachable only with explicit evidence or a recorded decision, never by default through silence or a failed re-review.

### D7. Proof Integrity stays a three-state value

`valid | incomplete | invalid` is not split into new states. "Normal absence due to a lagging version" and "absence due to tampering or loss" both map onto the existing semantics of `incomplete`/`invalid`, and the distinction between causes lives in the Integrity report's `reason` field (for example `legacy-version-gap` versus `missing-file`) rather than in the top-level state.

### D8. Head Commit is the true final HEAD

A Bundle's Head Commit is the actual HEAD at the end of the Run, including commits produced during the Finalize phase (such as methodology analysis); it is never narrowed to fit review coverage. When Head Commit is newer than Reviewed Commit, the Loop-Verified badge is withheld (its precondition is unmet) but the Bundle exports as usual. Defining head as "wherever review reached" in order to earn a badge is not allowed — that would hide unreviewed tail changes outside the Bundle, violating AC-9. CONTEXT.md has gained both Head Commit and Reviewed Commit entries.

### D9. Delivery Verdict is relative to the export profile

The verdict and per-AC statuses are judgments *relative to the Verification Profile used for this export and the evidence set it admits*, not profile-independent objective truth. The same Run exported under `local-v0` and `public-v0` may legitimately reach different conclusions; once the evidence supporting an AC is redacted, that AC is judged `unverifiable` in that Bundle and must not inherit `met` from a fuller profile.

### D10. Introduce a profile-independent `run_id`

- `run_id`: derived from a canonical hash of the Run's inherent facts (base/head commit, session timestamp, round structure), independent of the disclosure profile. Two Bundles sharing a `run_id` prove they came from the same Run — covering the "the maintainer asks to see the full version" verification scenario. Being a hash, it discloses nothing that a profile redacts.
- `proof_id`: still the Bundle identity at the (Run, profile) level. One Run exported under two profiles yields two different `proof_id` values and one shared `run_id`.
- AC-2 is refined accordingly: same Run + same profile, re-exported → same `proof_id`; same Run + any profile → same `run_id`.

## 3. Derivation and Implementation Strategy

### D11. per-AC status uses conservative mapping

Trust only structured facts enforced by the Stop hook: goal-tracker section moves (an AC entering "Completed and Verified"), finding associations, the `[P0-P9]` / `COMPLETE` / `Mainline Progress Verdict` markers, and Terminal State. Raw natural-language review text is displayed as evidence only, with no heuristic deep parsing; anything unparseable becomes `unverifiable`. Structured sidecars are the right way to lower the `unverifiable` rate in P1. See [ADR-0002](adr/0002-conservative-verdict-derivation.md).

### D12. The Proof layer uses the Python 3.9+ standard library

This breaks the repository's pure-Bash convention; the rationale and consequences are in [ADR-0003](adr/0003-python-for-proof-layer.md). The sub-choice for the JSON Schema validator (hand-written subset validator versus a vendored pure-Python implementation) is left to implementation planning, but no dependency requiring `pip install` may be introduced.

### D13. All three golden Runs are produced for real

Milestone 0's three sample Runs (a clean `complete`, a `complete` after review rework, and a deliberate `stop` or `cancel`) are all produced by real Claude+Codex RLCR runs on small tasks, with the artifact directories stored whole as fixtures — fixture fidelity is the foundation of Compiler compatibility, and structural differences such as rework-round prompt files and `stop-state.md` fields are exactly what hand-built fixtures miss. The tampered Bundles used for tamper tests are copied from real fixtures and then modified programmatically; they need no real run.

### D14. Implemented in the same repository as Loop

It lands inside the loop repository following the Draft §9.3 layout (`proof/` + `scripts/proof-*.py` + `tests/fixtures/proof/`). The contract will iterate quickly under dogfooding, and sharing the repository lets golden-fixture compatibility tests run in the same CI as Loop itself; splitting it out can be reconsidered once the `proof.json` contract is stable.

### D15. Explorer static packaging: inlined data + separated canonical interface

AC-7's "no network required" has to cover the case of double-clicking `index.html` open over `file://`, and `fetch('proof.json')` is blocked there by the same-origin policy. The approach:

- at export time, derive `proof-data.js` (`window.PROOF = {...}`) from `proof.json`; `index.html` loads it via `<script src>`, so a double-click is enough;
- the original Evidence files remain individual files in the directory, and the UI links to them with relative `<a href>`;
- `proof.json` remains the only canonical machine interface and `loop proof verify` remains data-canonical, so display-only tampering does not alter its result;
- `loop proof open` is the recommended verified viewing path: before opening it validates the Bundle, verifies the renderer assets bound by `explorer.assets`, and checks that `proof-data.js` is the exact derivation of `proof.json`. Direct `file://` double-clicking remains a portable convenience path, but it is visibly non-verifying and must not be treated as a trust decision.

### D16. The Compiler never emits `reject` automatically

`accept | changes_required | unverifiable` can be derived mechanically from structured facts; `reject` ("clearly fails the goal or violates a fixed boundary") requires a judgment of intent, and current Loop artifacts carry no corresponding structured signal. The schema enum keeps `reject` reserved for P1's manual acknowledgment or a structured Reviewer sidecar; the MVP exporter only produces the other three. See [ADR-0002](adr/0002-conservative-verdict-derivation.md).

## 4. Summary of Specific Revisions to Draft v0.1

| Draft location | Revision |
|---|---|
| §4 "complete is not a precondition for export" | Refined to "all five terminal states can be exported, active Runs are refused" (D2) |
| §6 proposed schema work | `run_id` added alongside `proof_id` (D10); the Evidence ID key is fixed as path + hash (D4) |
| §7.2 Delivery Verdict table | `reject` marked "not produced automatically in the MVP" (D16); verdict is relative to profile (D9) |
| §7.3 badge conditions | "reviewed commit matches head commit" grounded in the Head/Reviewed Commit terms (D8) |
| §5.2 / §10 AC-4 | Replan adjustment rules for the required AC set (D5); the conservative mapping source list (D11) |
| §5.4 Findings | The boundary between `open` and `unverifiable`, and the entry conditions for `resolved`/`waived` (D6) |
| §9.2 technology choices | The Python 3.9+ version floor and schema validator constraints (D12, ADR-0003) |
| §9.3 / explorer | The derived `proof-data.js` file added (D15) |
| §12 Milestone 0 | Golden Runs are obtained by real runs (D13) |

## 5. Decision Added During the Specification Stage

### D17. A Run Recorder added on the Loop side (added 2026-07-26)

A code review revealed that Loop currently records neither the Reviewed Commit nor the Head Commit at the end of a Run (`hooks/loop-codex-stop-hook.sh` contains no `git rev-parse HEAD`, and `end_loop()` only renames the state file). Yet both values are inputs to `run_id` (D10) and preconditions for the Loop-Verified badge (D8). Inferring them from file mtimes is exactly the kind of heuristic ADR-0002 rejects; filling both with `null` makes the badge unreachable throughout the MVP.

Decision: add two fact-only writes inside Loop — record `reviewed_commit` / `reviewed_at` / `reviewed_base` when `codex review` runs, and append `head_commit` / `ended_at` before `end_loop()` performs its rename. State frontmatter is parsed field by field by `_parse_state_fields()` with unknown fields ignored, and the hook already writes fields such as `current_round` and `review_started`, so this touches none of the RLCR state machine's decision logic. For legacy Runs missing these fields, both values are `null` and carry a `legacy-version-gap` warning.

## 6. Implementation Sub-choices (settled in the specification)

The four sub-choices originally left to Milestones 1-2 are settled in [`proof-of-loop-mvp-spec.md`](proof-of-loop-mvp-spec.md):

- JSON Schema validator → a hand-written subset validator (modern `jsonschema` depends on the Rust extension `rpds-py`, so vendoring a pure-Python implementation is not viable);
- `run_id` canonical hash field list and serialization rules → spec section D, including the fixed test vector requirement;
- Integrity report `reason` enum → the versioned enum and integrity status mapping table in spec section J;
- `loop proof open` implementation → validate the Bundle and renderer before opening over `file://`, with an optional loopback-only `--server` wrapper.
