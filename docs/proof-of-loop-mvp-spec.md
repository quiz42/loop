# Proof of Loop MVP: Implementation Specification

> Version: v1.1
> Date: 2026-07-26
> Lineage: [`proof-of-loop-mvp-design.md`](proof-of-loop-mvp-design.md) Draft v0.1 → (revised section by section) [`proof-of-loop-mvp-decisions.md`](proof-of-loop-mvp-decisions.md) D1-D17 → this specification
> Terminology is governed by [`CONTEXT.md`](../CONTEXT.md) at the repository root; architectural constraints by the three ADRs in [`adr/`](adr/); facts about existing Loop artifacts by [`repository-research.md`](repository-research.md) and a direct re-check of `hooks/` and `scripts/` for this specification.
> This specification settles the four implementation sub-choices left open by the decision appendix and adds one confirmed decision, D17 (Run Recorder, see Implementation Decision M).

## Problem Statement

When a maintainer receives a PR or branch produced by an AI agent, they cannot answer five questions in any reasonable amount of time: what did this delivery originally promise? Is each acceptance criterion satisfied, and where is the evidence? What problems and fixes happened in between? Which commit did the final review target, and are there unresolved findings? Is the evidence itself complete, has it been modified, and what has been withheld?

Loop already produces all the raw material needed to answer these questions, but it is scattered across Markdown files, YAML frontmatter, state-file renames, and Codex output under `.loop/rlcr/<timestamp>/`: readable only by the person who ran the Loop, on their own machine, relying on their memory of Loop's internal conventions. That material cannot be carried, verified, or shared without exposing prompts and local paths.

The result is that Loop's process rigor produces no trust value for a third party. The maintainer either blindly trusts the agent's own summary, or re-reviews everything manually from scratch — which is exactly the cost Loop set out to eliminate.

## Solution

Proof of Loop adds an evidence product layer above Loop that compiles one finished Loop Run into a **portable, verifiable, offline-browsable Proof Bundle**: an ordinary directory holding one canonical `proof.json`, the Evidence Items it references, and a zero-dependency static Explorer.

Three commands form the complete loop:

```bash
loop proof export --latest --profile public-v0   # compile: read-only Run + Git -> Proof Bundle
loop proof verify .loop/proofs/<proof-id>/       # validate: schema / hash / references / required evidence
loop proof open   .loop/proofs/<proof-id>/       # browse: offline Explorer, double-click to open
```

The product's core promise is **honesty rather than good looks**: Proof Integrity (is the evidence complete and untampered), Terminal State (did the Run finish), and Delivery Verdict (does the delivery meet its criteria) stay separate in both data and UI; anything not derivable from structured facts is marked `unverifiable`, never turned green by natural-language heuristics. What the maintainer receives is an evidence package that can attest to its own completeness, not a "verified" rubber stamp.

## User Stories

### Export (Evidence Compiler + CLI)

1. As a developer who just finished a Loop, I want to export the most recent Run with a single `loop proof export --latest`, so that I do not have to remember the session timestamp directory name.
2. As a developer who has run several Loops, I want to point at any historical Run with `loop proof export --run .loop/rlcr/<timestamp>`, so that I can export past runs after the fact.
3. As a developer, I want export to be explicitly refused with "the Run has not finished" when the Run has not reached a terminal state, so that I never receive half-finished evidence compiled from concurrently written state.
4. As a developer, I want the four terminal states other than `complete` — `stop`, `cancel`, `maxiter`, `unexpected` — to be exportable too, so that failed and aborted runs retain their retrospective value.
5. As a developer, I want to be certain the export is entirely read-only and never touches the source Run directory, the Git index, the working tree, or commit history, so that I dare export at any time, including while working on another branch.
6. As a developer, I want a specific warning when export hits a legacy format or a missing file (which file, what is missing, which conclusion it affects) rather than a crash or a silent skip, so that I know where this Bundle is weak.
7. As a developer, I want unknown fields to produce a warning rather than be discarded, so that new artifacts added by a Loop upgrade do not quietly vanish from the evidence.
8. As a developer, I want to choose `--profile local-v0` to get a self-use version containing all local detail, so that I lose no information during my own retrospective.
9. As a developer, I want `--profile public-v0` (the default) to automatically exclude prompts, transcripts, absolute paths, and BitLesson body text, so that I can send the directory out without inspecting every file by hand.
10. As a developer, I want a public export that detects a suspected secret to **fail outright**, telling me the file and the match type without echoing the secret itself, so that I never send credentials to a public channel.
11. As a developer, I want re-exporting the same Run under the same profile to produce exactly the same `proof_id`, so that I can confirm two Bundles are the same evidence.
12. As a maintainer, I want the public and local versions of one Run to share one `run_id`, so that when I ask the author for the full version I can verify it really is the same Run and not a prettier second attempt.
13. As a developer, I want export time, machine name, and tool paths — transport metadata — to **not affect** `proof_id`, so that identity is determined only by evidence content.
14. As a developer, I want the exported Bundle to stay under 10 MB by default, with oversized logs kept as a summary plus hash, so that it can travel as an email attachment or a CI artifact.

### Validation (Proof Validator)

15. As a maintainer, I want to run `loop proof verify` on a Bundle I received and get one of `valid | incomplete | invalid`, so that I know whether I can trust the contents.
16. As a maintainer, I want any modification to a non-redacted Evidence Item to yield `invalid` with the specific item named, so that tampering cannot be hidden.
17. As a maintainer, I want a modification to `proof.json` itself to yield `invalid`, so that editing a verdict field to fake a green result is exposed immediately.
18. As a maintainer, I want a Bundle that merely "lacks evidence the profile requires" (rather than having been modified) to yield `incomplete` rather than `invalid`, so that I can distinguish "evidence is incomplete" from "someone tampered with this".
19. As a maintainer, I want the Integrity report to carry a `reason` enum value for each problem (such as `legacy-version-gap` / `missing-file` / `hash-mismatch`), so that I know whether to ask the author for more material or to be suspicious.
20. As a maintainer, I want verify to emit both machine-readable JSON (`--json`) and a human-readable summary, so that it serves both CI and people.
21. As a CI engineer, I want verify to return stable, distinct exit codes for different outcomes, so that I can wire it straight into a pipeline condition.
22. As a maintainer, I want assurance that the Validator calls no LLM and accesses no network, so that the same input always yields the same integrity conclusion.
23. As a maintainer, I want the Validator to recognize only `proof.json` as the canonical interface, so that changing the Explorer's display data cannot fool validation.
24. As a maintainer, I want to be told explicitly when a Bundle's Reviewed Commit differs from its Head Commit, so that I know some code was not covered by review.

### Browsing (Proof Explorer)

25. As a maintainer, I want to see everything by **double-clicking `index.html`** after unpacking — no server, no network, no login — so that review has zero friction.
26. As a maintainer, I want one screen of Overview showing Proof ID, repository, base/head commit, Terminal State, Delivery Verdict, Proof Integrity, the profile used, and scale statistics, so that I form an overall judgment within tens of seconds.
27. As a maintainer, I want the coverage disclaimer always visible on the Overview (covers only these ACs, this commit, this profile), so that I never misread it as "the code is proven correct".
28. As a maintainer, I want the Acceptance Matrix to show each AC's status (`met | partial | unmet | unverifiable`), rationale, and links to supporting and contradicting evidence, so that I can jump straight to the raw material to check.
29. As a maintainer, I want an AC with zero evidence to never display as `met`, so that "nobody verified this" is never presented as "this passed".
30. As a maintainer, I want ACs removed from the required set to remain listed in the matrix, marked `deferred`, with the replan record attached, so that quietly withdrawing a hard AC to manufacture an accept has nowhere to hide.
31. As a maintainer, I want the Run Timeline to show Setup, each Round, the Review Phase, Finalize, and the terminal state, along with each round's mainline verdict (`advanced | stalled | regressed`), so that I can see whether the run progressed steadily or went in circles.
32. As a maintainer, I want plan evolution, replan, and circuit-breaker events on the Timeline, so that I know whether the goal was changed mid-flight.
33. As a maintainer, I want the Findings view to show each finding's severity, round discovered, affected files, raw evidence, fix commit, and re-review result, so that I can verify whether "we fixed it" actually happened.
34. As a maintainer, I want a finding whose re-review evidence cannot be linked to display as `unverifiable` rather than `resolved`, so that silence is not treated as a pass.
35. As a maintainer, I want the Evidence & Integrity view to show each file's hash, size, and status, so that I can spot-check for myself.
36. As a maintainer, I want missing, redacted, and unparseable to have clearly different visual treatments, so that I never misread "withheld" as "absent".
37. As a maintainer, I want one-click navigation from any conclusion to the raw Evidence file that supports it, so that I can verify rather than believe.
38. As a maintainer, I want the Loop-Verified badge to appear only when Integrity is `valid`, the Verdict is `accept`, Reviewed Commit equals Head Commit, and the profile is explicit, so that the badge has a definite meaning whenever it appears.
39. As an author, I want the Bundle to export and browse normally when the badge is not earned, so that I am never tempted to trim evidence to obtain it.
40. As a maintainer, I want the badge's full qualifiers visible in the UI (profile name, AC count, reviewed commit), so that it cannot be screenshotted into an unconditional "verified".

### Distribution and Collaboration

41. As an author, I want the Bundle directory to remain fully usable after being copied, archived, or uploaded as a CI artifact, so that sharing depends on no service.
42. As a maintainer, I want to open a received Bundle in a completely offline environment (on a plane, on an intranet), so that review is not limited by network access.
43. As an author, I want `loop proof open` to open the local Bundle directly in a browser, so that I can self-check before sending it out.
44. As an author, I want an explicit redaction declaration in the Bundle (which items were withheld and why), so that I can explain the gaps to the maintainer and they can judge whether to request the full version.

### Compatibility and Evolution

45. As a developer with historical Runs, I want Runs lacking newer recorded fields to still export, with the affected conclusions downgraded and a `legacy-version-gap` warning, so that upgrading Loop does not turn old runs into waste.
46. As a Loop maintainer, I want the Explorer to never parse historical Markdown directly, with all compatibility logic concentrated in the Run Adapter, so that a change in Loop artifact format requires editing only one place.
47. As a Loop maintainer, I want `proof.json` to carry a schema version and an explicit unknown-field policy, so that later evolution does not break already-distributed Bundles.
48. As a Loop maintainer, I want the Proof layer to modify none of the RLCR state machine's existing behavior, so that introducing the evidence layer brings no runtime regression.

## Implementation Decisions

### A. Module split and the single contract

The MVP consists of six compile-time modules plus a validator and a static Explorer, landing in the same repository as Loop (D14), following the Draft §9.3 layout (`proof/` + `scripts/proof-*.py` + `tests/fixtures/proof/`):

| Module | Responsibility | Boundary |
|---|---|---|
| Run Adapter | Read-only parsing of `.loop/rlcr/<session>/` artifacts and Git metadata into an internal intermediate representation; all backward-compatibility logic lives only here | The only place allowed to know Loop's Markdown formats |
| Evidence Compiler | Collect Evidence Items, compute SHA-256, assemble the Bundle objects | Performs no natural-language inference |
| Verdict Deriver | Derive per-AC status, Finding lifecycle, and Delivery Verdict from structured facts | Reads only the intermediate representation; rules in F/G |
| Profile Engine | Decide include/omit per item according to the Verification Profile, run the secret/path scan, produce the disclosure declaration | The only place that decides "what enters the Bundle" |
| Canonicalizer | Canonical JSON serialization, `run_id` / `proof_id` computation | Shared by Compiler and Validator so both use one algorithm |
| Bundle Writer | Write out `proof.json`, the evidence file tree, `proof-data.js`, and the Explorer static assets | Writes only the target directory |
| Proof Validator | Schema, hash, cross-reference, profile required evidence, `proof_id` recomputation | Calls no LLM, accesses no network |
| Proof Explorer | Zero-dependency static pages for the five views | Reads only `window.PROOF`, never parses Markdown |

`proof.json` is the **only** stable interface between Compiler, Validator, and Explorer (Draft §9.1).

### B. Proof Bundle structure and schema

A Bundle is an ordinary directory:

```text
<bundle>/
├── proof.json          canonical machine interface, the only thing the Validator checks
├── proof-data.js       display copy derived from proof.json: window.PROOF = {...} (D15)
├── index.html / app.js / styles.css
└── evidence/<run-relative-path>    original Evidence files, keeping their Run-relative paths
```

`evidence/` keeps Run-relative paths rather than content-addressed directory names, because the Evidence ID already contains the path (D4), paths are therefore naturally unique, and it keeps the UI's `<a href>` links readable.

Top-level objects in `proof.json` (`proof-bundle-v0.schema.json`):

```jsonc
{
  "schema_version": "proof-bundle-v0",
  "proof_id":  "sha256:...",   // see D
  "run_id":    "sha256:...",   // see D
  "profile":   { "name": "public-v0", "version": "0", "schema_hash": "sha256:..." },
  "source":    { "repo_name": "...", "base_commit": "...", "head_commit": "...|null",
                 "reviewed_commit": "...|null", "loop_version": "0.1.0", "exporter_version": "..." },
  "commits":   [ { "sha": "...", "subject": "...", "authored_at": "...",
                   "author_name": "...", "author_email": "..." } ],
  "specification": { "goal": "...", "acceptance_criteria": [ { "id": "ac-1", "text": "...", "text_sha256": "..." } ] },
  "run": { "session_timestamp": "...", "terminal_state": "complete|stop|cancel|maxiter|unexpected",
           "rounds": [ ... ], "events": [ ... ] },
  "evidence":  [ { "id": "...", "path": "...", "sha256": "...", "bytes": 1234,
                   "kind": "round_summary", "status": "included|omitted|truncated",
                   "omitted_reason": "profile-redaction|null" } ],
  "findings":  [ { "id": "...", "severity": "P0..P9", "status": "open|resolved|waived|unverifiable",
                   "found_round": 2, "evidence_refs": [...], "ac_refs": [...] } ],
  "verdict":   { "decision": "accept|changes_required|unverifiable",
                 "per_ac": [ { "ac_id": "ac-1", "status": "met|partial|unmet|unverifiable|deferred",
                               "reason": "...", "supporting": [...], "contradicting": [...] } ],
                 "required_set": ["ac-1", "..."], "deferred": [ { "ac_id": "ac-3", "replan_ref": "..." } ] },
  "integrity": { "compile_warnings": [ { "reason": "...", "target": "...", "detail": "..." } ] },
  "disclosure":{ "omitted": [ { "path": "...", "reason": "..." } ], "field_redactions": [ ... ] },
  "transport": { "exported_at": "...", "exporter_host_class": "..." }   // excluded from proof_id
}
```

`verification-profile-v0.schema.json`: `name`, `version`, `description`, `required_evidence_kinds[]`, `omit_paths[]` (glob), `omit_kinds[]`, `field_redactions[]`, `secret_scan.fail_on[]`, `secret_scan.omit_on[]`, `max_bundle_bytes`, `max_item_bytes`, `require_reviewed_equals_head` (affects the badge only, never integrity).

The Bundle records the profile document's own `schema_hash`, making "which rule set produced this export" itself verifiable.

The v0 schemas use two registered Proof annotations in addition to the supported
JSON Schema subset:

- `x-canonical-payload: true` on a root Proof schema requires the handwritten
  Validator to reject a floating-point value at any depth, including inside an
  otherwise unknown extension property, before canonical identity is computed;
- `x-unknown-field-policy: "warn"` is inherited by nested object schemas:
  unknown object properties allowed by `additionalProperties: true` are retained
  and reported as warnings. `additionalProperties: false` still rejects a
  property outright.

These annotations are executable requirements for the Proof Validator; a generic
JSON Schema reader can ignore them. The handwritten Validator rejects an
unregistered assertion keyword, Proof extension, or malformed supported keyword
rather than silently dropping a future constraint. The forward-compatibility policy applies to **property names**,
not values constrained by an `enum`: an unknown enum value is invalid for a
version-pinned v0 contract. An exporter classifies an unrecognized source artifact
as the declared evidence kind `unknown` instead.

The handwritten v0 `pattern` subset is likewise deliberately narrow: every
committed pattern is an anchored complete-value expression, and the Validator
matches the whole value. This rejects a trailing newline in a hash or timestamp
and avoids claiming broad ECMA-262 compatibility that the stdlib-only subset does
not implement.

### C. Evidence Item identity and file-level integrity

- Evidence ID = the first 16 hex characters of `sha256(canonical_json({path, sha256}))`, extended to full length on collision. The path distinguishes position within the Run; the hash detects whether that file was tampered with (D4).
- Hashes are computed over **raw bytes**, with no newline or encoding normalization.
- **File evidence is all-or-nothing**: a profile never rewrites file content. To withhold an item, mark it `status: "omitted"`, keep its `path` and `sha256` (the source file's hash), and do not write the content into the Bundle. This keeps AC-3's tamper detection meaningful and avoids "a laundered file whose hash matches nothing".
- **Derived records (commit metadata) do allow field-level redaction**: the optional top-level `commits[]` records are not files and are checked against Git at export time rather than a file hash. `local-v0` retains `sha`, subject, author time/name, and author email; `public-v0` retains the non-email fields, omits `author_email`, and declares that omission in `disclosure.field_redactions`. In v0, `commit.author_email` is the sole supported field-redaction rule. A copied Run whose recorded range is unavailable in the current checkout emits an empty `commits[]` array rather than guessing a different range.
- Items exceeding `max_item_bytes` are written as `status: "truncated"`: a summary plus the original `sha256` and original byte count. The Validator only checks the declaration's self-consistency and records `truncated-evidence`.

### D. Canonicalization and the two IDs

Canonical JSON rules (a Proof-specific JCS subset, with Compiler and Validator sharing one implementation):

- UTF-8 output, non-ASCII not escaped;
- object keys sorted ascending by Unicode code point;
- no superfluous whitespace (separators `,` and `:`);
- **floating-point numbers are forbidden in the canonical payload** (enforced at the schema level), sidestepping float formatting ambiguity; times are ISO-8601 UTC at second precision with `Z`.

The code-point ordering rule above is normative for v0. It deliberately differs
from strict RFC 8785 UTF-16 code-unit ordering when an astral-plane key and a
high-BMP key appear together; changing it would change identities and therefore
requires a new contract version.

`proof_id = "sha256:" + hex(sha256(canonical_json(payload)))`, where payload is `proof.json` minus `proof_id` and minus the entire `transport` object.

`run_id = "sha256:" + hex(sha256(canonical_json({
  "algo": "run-id-v0", "base_commit", "head_commit", "session_timestamp",
  "terminal_state", "round_indices": [0,1,2,...] })))` (D10).

The field list deliberately contains only the Run's inherent facts and **nothing profile-related**, so the public and local versions share a `run_id`; keeping it small also means Adapter detail changes will not make the same Run's `run_id` drift. Missing fields serialize as `null` (so legacy Runs stably receive a degraded but deterministic `run_id`).

Both algorithms come with **fixed test vectors**: the input JSON and expected hash are stored together, so any change in serialization behavior fails immediately.

An empty `specification.acceptance_criteria` array is schema-valid for a legacy or
unparseable Goal Tracker. The Compiler records `unparseable-artifact` for that
condition, yielding `incomplete` rather than the tamper-oriented
`schema-violation` result; it must never synthesize a cosmetic criterion.

### E. Export preconditions and Run discovery

- Only Runs that already have a terminal state file (`complete|stop|cancel|maxiter|unexpected`-`state.md`) are accepted (D2). A Run holding only `state.md` or `finalize-state.md` (Finalize is an active state) is refused, with an error explaining that the Run has not finished.
- `--latest` takes the first Run satisfying the terminal-state condition, ordered by session directory timestamp descending; if none exists, it errors and lists the most recent Runs with their current states.
- Reads only files inside the Run directory, the `plan.md` backup, and Git objects; never `.env`, credential directories, or files the Run does not reference.

### F. Input mapping (Run Adapter over existing artifacts)

Factual basis: `hooks/lib/loop-common.sh` (the `EXIT_*` constants, `end_loop()` rename rules, frontmatter parsing), `scripts/setup-rlcr-loop.sh` (state frontmatter, goal tracker and round templates), `hooks/loop-codex-stop-hook.sh` (review flow and `.review-phase-started`).

| Loop artifact | Mapping target |
|---|---|
| `state.md` frontmatter (terminal files share the structure) | `source.base_commit`, `run.session_timestamp`, round count, model configuration, `privacy_mode`, `drift_status`, `last_mainline_verdict` |
| Terminal file name `<reason>-state.md` | `run.terminal_state` (the five-value enum, from `EXIT_*`) |
| `plan.md` (Run-internal backup) | Source of `specification`, plus a `kind: plan` evidence item |
| `goal-tracker.md` IMMUTABLE section `### Acceptance Criteria` | The AC list; IDs assigned stably as `ac-N` in order of appearance, with `text_sha256` recorded |
| `goal-tracker.md` `Completed and Verified` table | The only structured source for an AC being `met` (includes Verified Round and Evidence columns) |
| `goal-tracker.md` `Explicitly Deferred` + `Plan Evolution Log` | The **only** legitimate basis for removing an AC from the required set (D5); a `deferred` item must cite the specific row |
| `goal-tracker.md` `Blocking / Queued Side Issues` | Source for finding association and for explicit `waived` records |
| `round-N-contract.md` | Timeline round objective and boundaries |
| `round-N-summary.md` | Builder self-report evidence (never a basis for AC judgment) |
| `round-N-review-result.md` | Findings (`[P0]`-`[P9]` markers), the `COMPLETE` marker, `Mainline Progress Verdict: ADVANCED/STALLED/REGRESSED` |
| `.review-phase-started` (`build_finish_round=N`) | Timeline Review Phase start point |
| `finalize-summary.md` / `methodology-analysis-report.md` / `methodology-analysis-done.md` | Finalize and methodology analysis events (the latter omitted by default under `public-v0`) |
| `.loop/bitlesson.md` | An evidence entry; the body is always omitted under `public-v0` (AC-6) |
| `git log base_commit..head_commit` | Commit evidence records |

Unrecognized files are not silently discarded: they are recorded as `kind: unknown` and produce a warning (AC-10).

### G. Delivery Verdict and Finding derivation (conservative mapping)

per-AC status trusts only structured facts the Stop hook enforces (D11, ADR-0002); raw natural-language review text is **evidence for display only**:

- `met`: the AC appears in `Completed and Verified` with a Verified Round, and no unresolved finding maps to it;
- `partial`: it has entered `Completed and Verified`, but a later round has a finding mapped to it that is not `resolved`;
- `unmet`: it has not entered `Completed and Verified`, and an open blocking finding maps to it;
- `deferred`: it appears in `Explicitly Deferred` and can cite the corresponding row in `Plan Evolution Log` — removed from the required set, but still visible in the matrix (D5);
- `unverifiable`: none of the above structured signals can be parsed (including the case where the AC section is still placeholder text).

**Zero evidence never yields `met`** (AC-4).

Finding lifecycle (D6):

- `open`: no subsequent fix round yet;
- `unverifiable`: a subsequent round exists, but its review result is missing, empty, or unparseable;
- `resolved`: a later, parseable, successfully produced review result exists in which the finding key no longer appears;
- `waived`: only when the Goal Tracker's Queued/Deferred tables carry an explicit record — neither silence nor a failed re-review constitutes `waived`.

Overall Delivery Verdict:

- `accept`: every AC in the required set is `met`, no blocking finding is `open` or `unverifiable`, Terminal State is `complete`, and the evidence the profile requires is complete;
- `changes_required`: `partial`/`unmet` statuses or unresolved findings exist;
- `unverifiable`: what obstructs judgment is mainly a parsing gap rather than a definite shortfall;
- `reject`: **never produced automatically in the MVP**; the schema enum reserves it for P1's manual acknowledgment or a structured sidecar (D16).

Both the verdict and per-AC statuses are **relative to this export's profile and the evidence set it admits** (D9): an AC whose supporting evidence is redacted is judged `unverifiable` in that Bundle and must not inherit `met` from a fuller profile.

### H. Profiles and redaction

`local-v0`: contains all Run artifacts and full commit metadata; `required_evidence_kinds` covers plan, goal_tracker, state, and each round's contract/summary/review_result.

`public-v0` (default):

- **whole-item omit**: `round-N-prompt.md`, `round-N-review-prompt.md`, any transcript or log, `.loop/bitlesson.md`, `methodology-analysis-report.md`;
- **field-level redaction**: commit author email;
- **required evidence**: plan, goal_tracker, terminal state, and each round's summary and review_result; missing → `incomplete`;
- **scanning**: a `secret`-class hit (PEM headers, common cloud credential prefixes, `token=`/`api_key=` assignments, high-entropy strings) → **export fails**, with an error naming the file and match type but never echoing the secret value; a `path`-class hit (absolute home paths such as `/Users/<name>/`, `/home/<name>/`) → the item is downgraded to omitted with a warning and counted in the disclosure, without blocking the export.

The rationale for two tiers: a secret leak is irreversible and its target metric is zero, while absolute paths are privacy noise rather than an incident, and hard-failing on them would make public export unusable on real projects.

### I. Loop-Verified badge

Displayed only when all hold: Proof Integrity `valid`; Delivery Verdict `accept`; `reviewed_commit == head_commit` (D8 — either being `null` fails the condition); the profile is explicit and version-pinned. The UI must display the coverage scope alongside it, in the form:

```text
Loop-Verified · public-v0 · 8/8 AC met · reviewed at 8f31c2a
```

Head Commit is always the true HEAD at the end of the Run, never narrowed to "wherever review reached" in order to earn a badge (D8).

### J. Validator behavior and exit codes

Validation order: schema → file existence → per-item hash → cross-references (all `ac_refs`/`evidence_refs`/`findings` resolvable) → `proof_id` recomputation → profile required evidence → consistency checks (such as `reviewed_commit` versus `head_commit`).

Integrity status mapping (D7 — three states unchanged, causes live in `reason`):

| reason | Result |
|---|---|
| `schema-violation` | `invalid` |
| `hash-mismatch` | `invalid` |
| `proof-id-mismatch` | `invalid` |
| `dangling-reference` | `invalid` |
| `duplicate-evidence-id` | `invalid` |
| `missing-file` (declared in the Bundle but absent from the directory) | `invalid` |
| `profile-required-evidence-missing` | `incomplete` |
| `legacy-version-gap` (legacy Run missing recorded fields) | `incomplete` |
| `unparseable-artifact` | `incomplete` |
| `truncated-evidence` | `incomplete` (`valid` + warning when the profile permits) |
| `head-commit-unknown` / `reviewed-commit-unknown` | `incomplete` |
| `reviewed-commit-behind-head` | Does not downgrade integrity; withholds the badge only (D8) |
| `redacted-by-profile` | No downgrade; recorded in the disclosure |
| `size-budget-exceeded` | No downgrade; warning |

Exit codes: `0` valid; `2` incomplete; `3` invalid; `1` usage/environment error (kept distinct for CI).
Export exit codes: `0` success; `1` usage/environment error; `2` Run not in a terminal state; `3` secret scan failure; `4` Run unreadable.

### K. Explorer packaging

- At export time, derive `proof-data.js` (`window.PROOF = {...}`) from `proof.json`; `index.html` loads it via `<script src>`, so double-clicking over `file://` works (D15 — avoiding the same-origin policy's block on `fetch`);
- the original Evidence files remain individual files in the directory, and the UI navigates to them with relative `<a href>`;
- `proof.json` is the only canonical interface and the only thing the Validator checks — tampering with `proof-data.js` can only fool someone reading that one HTML page, never `loop proof verify`;
- native HTML/CSS/JS, no build step, no CDN, no web fonts.

### L. CLI integration

The `loop()` function in `scripts/loop.sh` currently has only a `monitor` branch; add a `proof` branch that forwards to `scripts/proof-export.py` / `proof-verify.py`:

```bash
loop proof export [--latest | --run <dir>] [--profile <name>] [--out <dir>]
loop proof verify <bundle-dir | proof.json> [--json]
loop proof open   <bundle-dir>
```

- The entry point performs a **Python 3.9+ prerequisite check** (ADR-0003), giving an actionable installation hint when it is missing; the repository already has `hooks/check-todos-from-transcript.py` depending on `python3`, so this is not a new burden.
- Default output goes to `.loop/proofs/<first 12 chars of proof-id>/`; `.loop/` is already blocked from entering Git by Loop's write validators, so no extra gitignore work is needed.
- A non-empty `--out` directory must already contain a schema-valid, identity-matching Proof Bundle. Re-exporting replaces that managed Bundle as a whole so a later public export cannot retain raw evidence from an earlier local one; arbitrary nonempty directories are rejected untouched.
- `proof open`: the MVP opens over `file://` (macOS `open`, Linux `xdg-open`), and provides an optional `--server` wrapper (`python3 -m http.server` bound to `127.0.0.1` on an ephemeral port) as an experience improvement — this settles the fourth sub-choice in the decision appendix.

### M. Run Recorder: one Loop-side addition (D17, confirmed)

A code re-check surfaced an upstream factual gap: **Loop currently records neither the Reviewed Commit nor the Head Commit at the end of a Run.** `hooks/loop-codex-stop-hook.sh` contains no `git rev-parse HEAD`, and `end_loop()` (`hooks/lib/loop-common.sh`) only renames the state file without appending any field. This means the Proof layer cannot honestly obtain those two values from existing artifacts — and they are simultaneously inputs to `run_id` (D10) and preconditions for the Loop-Verified badge (D8).

Three options and their trade-offs:

- **Pure derivation (rejected)**: match commit timestamps against review result file mtimes. This is precisely the heuristic ADR-0002 rejects: its failure mode is "looks precise, actually a guess".
- **Always `null` (fallback)**: honest, but the badge becomes permanently unreachable in the MVP, leaving the product's strongest signal inert.
- **Recommended: add a fact-only Run Recorder** (adopted by this specification) —
  - when running `codex review`, write `reviewed_commit`, `reviewed_at`, and `reviewed_base` into the active state frontmatter;
  - before `end_loop()` renames, append `head_commit` and `ended_at` (the cancel path in `scripts/cancel-rlcr-loop.sh` goes through the same function or an equivalent write).

Safety argument: state frontmatter is parsed field by field with grep in `_parse_state_fields()`, and unknown fields are ignored, so new fields have zero impact on existing parsing and validation; state files are already written by the hook (for example `current_round`, `review_started`), so this is not a new mechanism. In scope terms this is "recording facts that already exist", touching none of the RLCR state machine's decision logic (the Draft §9.1 boundary holds).

Legacy Runs without these fields → both values `null`, a `legacy-version-gap` warning, no badge, and a `run_id` computed stably with `null` (AC-1 still satisfied).

> **This item was confirmed and adopted on 2026-07-26 (D17).** It is the only part of the MVP that modifies Loop itself; implement it as a separate commit with separate tests (`test-state-exit-naming.sh` and the review-flow suites need corresponding extension), reviewed apart from the Proof layer's new files.

### N. The four implementation sub-choices, now settled (decision appendix section 5)

1. **JSON Schema validator → a hand-written subset validator.** Vendoring is not actually viable: modern `jsonschema` depends on `referencing` + `rpds-py` (the latter a Rust extension, not pure Python), and the vendorable older versions are too dated. A hand-written validator needs to cover only the keywords our own schemas use (`type`, `required`, `properties`, `additionalProperties`, `enum`, `const`, `items`, `minItems`, `pattern`, and limited `oneOf`/`anyOf`), with positive and negative cases for each schema. This also satisfies ADR-0003's "no dependency requiring pip install".
2. **`run_id` field list and serialization → see section D**, including the fixed test vector requirement.
3. **Integrity `reason` enum → see the table in section J**; the enum values themselves are written into the schema.
4. **`loop proof open` → open over `file://` plus an optional `--server` wrapper**, see section L.

### O. Non-functional requirements

- a single Bundle stays under 10 MB by default; oversized items follow the truncation strategy in section C with a warning;
- within 1,000 Evidence Items, export and verify each complete within 5 seconds;
- canonicalization, hashing, and profile behavior all have fixed test vectors;
- both Linux and macOS in CI; Python 3.9+ added to the prerequisite check and the CI matrix;
- every public field has a schema description; unknown fields follow the schema version policy (warn on read, never discard).

## Testing Decisions

### What a good test looks like here

Test only **externally observable behavior**: the command's exit code, the files written, the contents of `proof.json`, the verifier's JSON report. Do not test Python internal function signatures, and do not test the shape of the intermediate representation — those will certainly change during dogfooding, while the contract will not. Every assertion should be a sentence that could go into product documentation ("tamper with any evidence file → verify returns 3"), not an implementation detail.

### Test seam

**One seam only: the CLI subprocess boundary.** Every P0 behavior is observable at the `loop proof export|verify` layer, so no second seam is introduced:

```text
tests/fixtures/proof/<golden-run>/   ->  proof-export.py  ->  <bundle dir>  ->  proof-verify.py  ->  exit code + JSON
```

Rationale: this is the highest available seam; it covers Adapter, Compiler, Profile Engine, Canonicalizer, and Writer at once, and is naturally resistant to internal refactoring. The hand-written schema validator is the only exception candidate (a pure function, with cheap positive/negative cases), but its correctness is equally coverable at the CLI layer using deliberately broken Bundles — so unless implementation reveals the coverage cost is too high, no new seam is opened.

Milestone 1 is the explicit temporary exception: before the CLI exists, its fixed
canonicalization, identity, and schema vectors test the public `proof.contract`
surface directly. Milestone 2 retains the CLI subprocess boundary as the sole
product-behavior seam; it must not add a second Adapter, Compiler, or Validator
test interface.

The Explorer's UI rendering is outside this seam: the MVP relies on manual walkthrough plus screenshots over the three golden Runs (Milestone 3), while automation asserts only that the static assets are all present and that `proof-data.js`, with its `window.PROOF = ` prefix stripped, is semantically equal to `proof.json`.

### Modules under test and cases

Following the repository's existing shell suite form (`tests/test-*.sh`, temp directory + `git init` + pass/fail counters), add two suites and register them in the `TEST_SUITES` array of `tests/run-all-tests.sh`:

**`test-proof-export.sh`**

- AC-1 compatibility: fixtures for all five terminal states each export successfully;
- an active Run (only `state.md` / `finalize-state.md`) is refused with exit code 2;
- AC-2 determinism: exporting the same Run with the same profile twice yields the same `proof_id`; changing export time or output directory does not affect `proof_id`;
- `run_id` consistent across profiles, `proof_id` different across profiles;
- AC-8 read-only: take a recursive hash snapshot of the whole Run directory before and after export and compare, plus `git status --porcelain` showing no change;
- AC-6 privacy: `public-v0` output contains no prompt files, BitLesson body text, or absolute home paths; a fixture with a planted fake secret fails export with exit code 3 and an error that does not echo the secret value;
- AC-4: a fixture whose AC section is placeholder text → every AC `unverifiable`, none `met`; a deferred fixture → the AC leaves the required set and carries a replan reference;
- AC-10: fixtures for a missing file, a legacy format, and an unparseable review result each produce a specific warning without crashing;
- a legacy Run (no `head_commit`/`reviewed_commit`) → export succeeds with `legacy-version-gap` and the badge condition unmet;
- comparison against the fixed test vectors for canonicalization and `run_id`/`proof_id`.

**`test-proof-verify.sh`**

- a clean Bundle → exit code 0, `valid`;
- AC-3 tampering: modify one Evidence file's bytes, modify a verdict field in `proof.json`, and delete a referenced file → exit codes 3/3/3 with `reason` values `hash-mismatch`, `proof-id-mismatch`, and `missing-file` respectively, and the report naming the specific target;
- missing profile-required evidence → exit code 2, `incomplete`;
- dangling references and duplicate Evidence IDs → `invalid`;
- `reviewed_commit` behind `head_commit` → integrity still `valid`, but the badge condition false (D8);
- `--json` output parseable with stable fields;
- tampering with `proof-data.js` without touching `proof.json` → verify still `valid` (proving the canonical interface boundary, D15).

### Fixture strategy

- all three golden Runs are produced by real Claude+Codex RLCR runs on small tasks, with the artifact directories stored whole (D13) — structures such as a rework round's prompt files and `stop-state.md`'s field differences are exactly what hand-built fixtures miss;
- tampered Bundles are copied from the real fixtures and then **modified programmatically**, requiring no real run;
- legacy-format fixtures are derived from a golden Run by deleting fields, with a file-header comment stating which version gap they simulate.

### Prior art in the repository

- `tests/test-state-exit-naming.sh`: how terminal-state naming and fixture state files are written, directly corresponding to the Adapter's terminal-state determination;
- `tests/test-stop-gate.sh`, `tests/test-finalize-phase.sh`: how a temporary Git repository plus hook subprocess invocation is organized;
- `tests/run-all-tests.sh`: suite registration, parallel scheduling, and mock binary injection; note that this runner cannot start under macOS system Bash 3.2 (`declare -A` and `date +%s%3N`), so new suites should be runnable standalone.

## Out of Scope

Explicitly not doing (following Draft §8 and D1):

- cloud accounts, databases, organization spaces, hosted web services, SSO;
- bounties, payments, staking, tokens, challenges, arbitration;
- wallets, DIDs, third-party identity systems, signing;
- private repository uploads; multi-reviewer quorum; automatic PR merging;
- claiming AI review as a mathematical proof or a security certification.

Not in this MVP, left to P1 and beyond:

- snapshot export of active Runs (D2 supports terminal states only);
- deep parsing of natural-language review text and parser confidence (ADR-0002);
- structured test result sidecars and structured Reviewer verdict sidecars (the right way to lower the `unverifiable` rate, but not in the MVP);
- automatic derivation of `reject` and the manual acknowledgment flow (D16);
- a local index page for multiple Proofs, GitHub Actions artifact templates, PR Markdown summaries, and badge embedding;
- Proof Bundle encryption, signing, and external Evidence Stores;
- cross-runtime / cross-Git-host adapters;
- Explorer search, filtering, diff views, and other advanced interactions (the MVP only presents the five views statically).

## Further Notes

### Confirmed decisions and the seam

- **D17 Run Recorder (section M)**: confirmed and adopted. Two fact-only writes are added on the Loop side (`reviewed_commit` at review time, `head_commit` at terminal state), making the Loop-Verified badge reachable within the MVP.
- **Single-seam testing strategy**: confirmed. All automated tests hit only the `loop proof export|verify` CLI subprocess boundary; no separate test entry points for the Adapter, Compiler, or Validator.

### Milestone mapping

- **Milestone 0**: produce the three real golden Runs (clean complete / complete after review rework / stop or cancel), and freeze the `public-v0` minimum evidence requirements;
- **Milestone 1**: both JSON Schemas, canonicalization, the `run_id`/`proof_id` algorithms with test vectors, and the hand-written schema validator;
- **Milestone 2**: Run Adapter + Compiler + Validator + CLI integration, with `test-proof-export.sh` / `test-proof-verify.sh` fully green;
- **Milestone 3**: the Explorer's five views + `proof open` + manual walkthrough over the three golden Runs;
- **Milestone 4**: dogfood on 5-10 public tasks, and revise `public-v0` and the schema accordingly.

### Acceptance criteria (Draft §10 calibrated by the decision appendix)

- **AC-1 Run compatibility**: Runs in all five terminal states can be exported; active Runs are explicitly refused.
- **AC-2 Stable identity**: same Run + same profile, re-exported → same `proof_id`; same Run + any profile → same `run_id`.
- **AC-3 Tamper detection**: modifying the manifest or any non-redacted Evidence Item → `invalid` with the target named.
- **AC-4 AC traceability**: every AC has a status, a rationale, and evidence references; zero evidence must never be `met`; a deferred AC must cite a replan record.
- **AC-5 Finding lifecycle**: the Explorer shows discovery, fix commit, and re-review result; when it cannot be linked it is `unverifiable`, never `resolved`.
- **AC-6 Privacy by default**: `public-v0` contains no full prompts, transcripts, absolute paths, secrets, or BitLesson body text, and emits a redaction declaration.
- **AC-7 Offline review**: the copied directory shows all public evidence by double-clicking `index.html`, with no network and no login.
- **AC-8 Read-only export**: export does not modify the source Run, Git index, working tree, or commit history.
- **AC-9 Honest status**: Proof Integrity, Terminal State, and Delivery Verdict stay mutually independent in both data and UI.
- **AC-10 Actionable failure**: missing files, legacy formats, and parse failures each produce a specific warning or error; never a crash, never a silent pass.

### North star and key metrics

North star: **maintainer time-to-trust** (the median time from opening a Proof to being able to decide "accept" / "request changes" / "cannot tell"). Supporting observations: export success rate, required evidence completeness rate, AC evidence coverage rate, finding-to-fix linkage rate, third-party verification success rate, manual override rate, share of `unverifiable` ACs, and public profile leakage incidents (target 0).

Agent lines of code, round count, model call volume, and badge count are not the north star.

### Known tension

- Conservative derivation will leave the MVP's `unverifiable` share on the high side. This is ADR-0002's deliberate trade-off: one "looks all green but is actually a parsing hallucination" does more damage to product trust than a batch of honest `unverifiable`s. The right way to lower it is the structured sidecars in P1, not looser parsing.
- A hand-written schema validator means we maintain a small piece of validation logic ourselves. Its boundary is defined by our own schemas, and every rule has positive and negative cases — more controllable than pulling in a Rust extension dependency or vendoring a dated implementation.
