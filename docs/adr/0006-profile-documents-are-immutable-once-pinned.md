# A profile document is immutable once a Bundle has pinned it; revisions are new names

Every Bundle pins the profile it was exported under by name, version, and the
hash of the profile document itself, and the Validator loads the current
document by that name and requires the pinned hash to match. That check is
what stops a producer from claiming a stricter disclosure policy than the one
actually applied. It also means the two records — the document in this
repository and the hash in every distributed Bundle — must never diverge.

ADR-0004 as first landed broke that rule: it added `mask_on` and `mask_kinds`
to `proof/profiles/public-v0.json` in place. Every Bundle exported under the
pre-masking `public-v0` then failed verification on `profile.schema_hash`,
exit 3, against the very consequence ADR-0004 recorded ("Bundles distributed
before this change carry no masked item and verify unchanged") and against
issue #12's acceptance criterion that prior Bundles still verify. The gap was
invisible to the suite because the compatibility test re-exported with
today's code — pinning today's hash — instead of verifying an archived
Bundle.

The rule this record fixes: **a profile document is immutable once any
distributed Bundle can have pinned its hash. A revision is a new profile
name.** `public-v0` is restored to its pre-masking bytes and frozen; the
masking revision ships as `public-v1`, which is now the default export
profile. A Bundle that pins `public-v0` is verified against the frozen
document and the rules it actually declared — no masking licence among them —
so an archived pre-masking Bundle verifies unchanged, byte for byte, which
`tests/fixtures/proof/bundles/pre-masking-public-v0` now asserts against the
current CLI.

## Considered Options

**Revising the document in place** was the status quo this record forbids.
It makes the name mean different contracts at different times, and the pinned
hash turns that ambiguity into a verification failure for exactly the
Bundles the unknown-field policy promises to keep alive.

**A historical registry keyed by the pinned hash** — keeping every prior
revision of a name on disk and selecting by hash — verifies the same Bundles
without a rename. Rejected because it makes one name ambiguous for humans:
"exported under public-v0" would no longer say which disclosure rules
applied, and every consumer-facing surface (badge, Explorer, disclosure)
names the profile, not its hash. The frozen-name rule keeps the name
meaningful and costs one file per revision.

## Consequences

- Bundles exported by the pre-masking exporter verify `valid` again with the
  current CLI; the masked-publication behavior and its tests move to
  `public-v1` unchanged.
- The nine-Run dogfood corpus was exported while masking briefly lived in
  `public-v0`; those local Bundles pin a hash no shipped document carries and
  must be re-exported under `public-v1`. They were never distributed.
- Any future change to a shipped profile document — even a description edit
  — is a new name. The pinned hash covers the canonicalized document content
  (keys sorted, compact separators, per the Proof v0 canonical JSON rules),
  so formatting and key order are free, and every field value is
  load-bearing. Moving to raw-byte hashing would itself change every pinned
  `schema_hash` and is therefore its own compatibility decision, not a
  cleanup.
