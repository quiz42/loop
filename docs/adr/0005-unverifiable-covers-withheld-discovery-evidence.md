# A finding whose discovery review is withheld is `unverifiable`, and the two causes of `unverifiable` stay distinguishable

PR #31 made the Compiler record the findings a withheld review result raised,
so a public Bundle stops reading as if the Run had found nothing. That left a
contract question the original definitions did not answer: spec section G and
`CONTEXT.md` defined `unverifiable` as "a fix was attempted but the re-review
evidence is missing or unparseable", while `open` meant "no fix has been
attempted yet". A finding minted from a withheld review fits neither sentence
— there need not have been any fix attempt, but the Bundle also cannot show
that there was none. The implementation chose `unverifiable`; the review of
PR #31 correctly objected that the written contract said otherwise and that a
maintainer could read the status as "a fix was attempted but cannot be
confirmed" when the actual state is an unaddressed discovery.

The decision: `unverifiable` is defined as *the lifecycle cannot be
established from the evidence this Bundle admits*, with exactly two causes,
and the cause must stay derivable from the Bundle itself — a consumer tells
them apart by whether the finding's `found_round` review result is published.
The Explorer renders the cause on the finding card so the two situations
cannot be confused. Spec section G and `CONTEXT.md` are amended accordingly.

## Considered Options

**`open` plus a withheld-provenance marker** was the reviewed alternative:
keep the lifecycle meaning of `open` ("no fix attempted") and add a field
saying the discovery evidence was withheld. Rejected because `open` asserts a
fact the admitted evidence cannot establish. Whether a fix was attempted
lives in later rounds' artifacts, which the same profile may also withhold;
and the same Run's `local-v0` Bundle may legitimately show the finding
`resolved`, at which point the public Bundle would be claiming an unaddressed
problem that the fuller Bundle disproves. Every lifecycle claim in
`proof.json` is one the Validator re-derives from published bytes (ADR-0002);
`open` here would be the one claim taken on faith. `unverifiable` asserts
nothing a recipient cannot check, which is the only honest floor.

**A new versioned lifecycle state** (for example `withheld`) would name the
situation precisely, at the cost of a schema enum change that makes every
existing consumer's exhaustive status handling reject otherwise-valid
Bundles, for a distinction the manifest already carries: the finding's
`found_round`, its `evidence_refs`, and the referenced item's `status` locate
the cause without a new field. Rejected while the derivable distinction
suffices; it remains the fallback if a consumer is ever unable to derive the
cause from the manifest.

**Dropping the findings of a withheld review entirely** was the pre-PR-#31
state and is what the dogfood showed to be dishonest: every public Bundle in
the corpus listed no findings while its local counterpart listed them.

## Consequences

- The direction stays one-way (D9): a finding minted from a withheld review
  never joins the active set, so no later review — included or not — moves it
  to `resolved`. Withheld evidence may show that a problem existed, never
  that one was fixed. If the later review independently records the same
  problem, that is a new finding with its own evidence.
- The cause of `unverifiable` is a derivation, not a declaration: nothing new
  is written into `proof.json`, prior Bundles keep verifying unchanged, and
  the unknown-field policy is untouched.
- A maintainer reading the Explorer sees "the review that discovered it is
  not published in this Bundle" against "a later review result is missing or
  unparseable" — the unaddressed-discovery case is never presented as a
  failed fix confirmation, which was the review objection this record
  resolves.
- Both readers of review results fail closed on malformed markers, withheld
  or included, so the finding set for one Run cannot differ across profiles
  because of a marker the parser rejected.
