# ADR-0008: Truncation is a disclosure boundary, so the summary carries no content

Status: accepted
Date: 2026-08-11
Supersedes: none
Related: [ADR-0002](0002-conservative-verdict-derivation.md), [ADR-0004](0004-masked-publication-of-path-bearing-evidence.md), [ADR-0005](0005-unverifiable-covers-withheld-discovery-evidence.md), [ADR-0006](0006-profile-documents-are-immutable-once-pinned.md)

## Context

Spec section C has always said an oversized Evidence Item is written as
`status: "truncated"`: "a summary plus the original `sha256` and original byte
count". The hash and the byte count shipped. The summary never did, and no
`summary` field existed in the Bundle schema. Issue #39 asked for it.

The obvious reading of "summary" is some of the withheld bytes -- a bounded
prefix, a first line, a heading. Three independent designs were drafted along
those lines and each was adversarially reviewed. All three were rejected, for
one reason that none of them started with.

**Truncation is a disclosure boundary in this codebase, not merely a size
accident.** `_evidence_is_published()` answers False for `truncated` exactly as
it does for `omitted`, and the Compiler strips derived facts across that line in
four places, each with the rationale written next to it:

| Unpublished item | What the Bundle stops carrying |
|---|---|
| `plan.md` | `specification.goal` becomes `""` |
| `goal-tracker.md` | `specification.acceptance_criteria` becomes `[]`, and finding-to-AC links are cleared |
| the terminal state file | `session_timestamp`, `loop_version`, `circuit_breaker` events and every event's `at` |
| a round review result | findings keep an id that is a hash of round, severity and normalized summary, "so no review prose enters the Bundle" |

Reviewers reproduced the consequence on shipped profiles rather than arguing it:

- under `public-v1`, a `plan.md` padded past the cap exports with
  `specification.goal == ""`, while the first kibibyte of that same file is the
  goal statement and the acceptance-criterion prose;
- under `local-v0`, an oversized state file exports with `session_timestamp:
  null` and `loop_version: "unknown"`, while its first kibibyte is the whole
  frontmatter including `session_id`;
- an oversized review result publishes findings as bare hashes, and a prefix
  restores the prose **and makes the hash invertible** -- feeding the prefix back
  through `_finding_key`/`_finding_id` reproduces the Bundle's own finding id.

Two further arguments died in review and are recorded because they are the ones
a future reader is most likely to re-invent:

1. *"A truncated item's bytes already passed the secret scan, so any prefix of
   them is equally publishable."* False twice over. `local-v0` has `fail_on: []`
   and scans nothing at all. And on the public profiles a prefix can match where
   the whole does not: a high-entropy candidate diluted below the 4.5 threshold
   by a long tail matches once the tail is cut, and a `\b`-anchored credential
   pattern is satisfied by the cut itself.
2. *"Intersect the withheld text against a closed vocabulary the Bundle already
   publishes -- acceptance-criterion ids, say -- so nothing new escapes."* This
   is a membership oracle. With the Goal Tracker omitted the Bundle publishes no
   criteria at all, so the intersection answers a question about the *omitted*
   file: the same truncated bytes under the same profile produce different
   summaries depending on how many criteria the withheld tracker defined. It
   breaks the leak rule and determinism in one move.

## Decision

The summary carries **shape, not content**:

```json
"summary": {"algo": "evidence-summary-v0", "lines": 30049, "longest_line_bytes": 76}
```

- `lines` is `data.count(b"\n")`, plus one when the artifact does not end in a
  newline. `longest_line_bytes` is the longest run between newlines. Both are
  counted on raw bytes: no decode, so undecodable evidence summarizes like
  anything else; no `splitlines`, which also breaks on U+2028 and U+0085 and
  would make the count depend on how the bytes decode; no line-ending
  normalization, so a CRLF artifact counts its own bytes. The implementation
  scans once without splitting, so newline-dense oversized artifacts do not
  allocate one object per line.
- `algo` names the derivation, as `run-id-v0` does in section D, so a holder of
  the source can recompute it.
- The object is **closed**. It is a disclosure bound, so an unknown member would
  be an unbounded channel for the bytes the decision exists to keep out.
- It is required when `status` is `truncated` and forbidden otherwise.

The absence rule is exact to the manifest-defined Evidence Item: no filesystem
entry may exist at its declared `evidence/<path>`. `proof.json` defines the
verified Evidence Item set; undeclared co-located files are unmanaged transport
content, excluded from `max_bundle_bytes`, and receive no Proof integrity,
disclosure or secret-safety claim. The Writer creates a clean managed projection;
the Validator does not authenticate the surrounding transport container.

Every member is checkable by the Validator against the item's own declared
`bytes`, with no external input: `lines <= bytes`, `longest_line_bytes <=
bytes`, `longest_line_bytes + max(lines - 1, 0) <= bytes`, and `bytes <= lines *
(longest_line_bytes + 1)`. The first three keep the declared shape within the
artifact; the last requires its lines to have enough capacity for every byte.
Together they are exact whether or not the artifact ends in a newline. That
checkability is the point: every other rule on a truncated declaration was added
because a claim nothing verifies is a claim the producer writes for itself.

The requirement is unconditional -- no version gate. No Proof Bundle carrying a
truncated item has been distributed: the repository has no tags, `origin/main`
has no `scripts/proof-export.py` at all, the archived `pre-masking-public-v0`
fixture carries only `included` and `omitted` items, and ADR-0006 records of the
Milestone 4 corpus that "They were never distributed." This is the same premise
ADR-0004 relied on when it made `masked_sha256`/`masked_bytes` required for
`status: "masked"`.

## Consequences

- Section C is satisfied literally: a truncated item now carries a summary, the
  original hash and the original byte count, and the Validator checks the
  declaration's self-consistency.
- A reader learns how the artifact was shaped and nothing about what it said.
  That is less than "summary" suggests in ordinary use, and the spec now says so
  in as many words rather than leaving the gap to be discovered.
- No profile document changes, so ADR-0006 is not triggered and there is no
  `local-v1`/`public-v2` cascade. `run_id` is unchanged -- its projection takes
  `round_indices` only. `proof_id` changes only for Bundles that actually carry
  a truncated item, which is no existing artifact.
- Real Runs almost never reach this path: the largest artifact anywhere in the
  fixture corpus is 10,655 bytes against a 1 MiB cap, so every truncated item in
  the suite is synthetic padding. The rule is defensive, and its value is that it
  closes a shape rather than that it fires often.

## Rejected alternatives

- **A bounded prefix of the withheld bytes**, scanned and masked. Rejected: the
  reproductions above, plus the prefix-rescan result that makes "already scanned"
  no guarantee for a substring.
- **A kind-aware structured summary**. Rejected: for `round_review_result` it
  duplicates `findings[]` and the `mainline_verdict` event, which both survive
  truncation, and creates a second copy that can disagree with the first; for
  plan, tracker and state it reverses the projection-stripping rules above; for
  transcript and log there is no parser.
- **Amending section C to say the summary is already satisfied** by `findings[]`,
  the `mainline_verdict` event and the `truncated-evidence` warning. This was
  the runner-up and is defensible -- it is the ADR-0005 move, derive rather than
  declare, and it costs nothing. It was not taken because those facts exist only
  for one evidence kind, so most truncated items would still carry nothing, and
  because weakening a written contract to match the implementation is the harder
  thing to justify later of the two.
- **Gating the requirement on `exporter_version`.** Rejected: that field is a
  free-form string and a public constructor parameter, and the repository's own
  contract vector sets it to `"0.1.0"`, so failing closed on unknown values would
  invalidate third-party Bundles rather than grandfather them.
