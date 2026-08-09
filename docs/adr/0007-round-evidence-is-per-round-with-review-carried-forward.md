# Round evidence is checked per round, and a review covers the rounds before it

Spec section H stated the round contract per round — H:289 gave `local-v0`
"each round's contract/summary/review_result", H:295 gave the public profiles
"each round's summary and review_result" — while the implementation checked
`required_evidence_kinds` **by kind across the whole Bundle**. One included
`round_summary` and one included `round_review_result` satisfied it, however
many rounds the Run recorded. PR #29 narrowed that to "every round needs at
least one of the two, and the final round needs both" without closing it,
because closing it either way is a product decision (issue #30).

Two real shapes decide it, and neither is a corner case.

**A round is often reviewed later than its own index.** `codex review` runs
against the cumulative diff from the Run's base commit, so the review at round
N covers the work summarized at round N and at every earlier round. Round 0 of
`cancel-after-review`, `complete-after-rework`, `maxiter-derived`,
`stop-derived` and `path-cited-review-complete` has a summary and no review
result of its own, and is reviewed in round 1. Enforcing H:295 literally
rejects all five.

**A clean re-review creates a round with no builder summary.**
`hooks/loop-codex-stop-hook.sh` numbers every review-phase artifact
`build_finish_round + 1` and upward. When Loop began recording a clean review
(issue #33), that record landed in a round that has a review result and nothing
else — and under "the final round needs both", every Run that passed its
re-review would have turned `incomplete`. That is why #33 could not be fixed
without settling #30 first.

## The rule

Evidence is owed per round, and what a round owes depends on which kind of
round it is. The boundary is `build_finish_round`, recorded by Loop in
`.review-phase-started`:

- an **implementation round** (`index <= build_finish_round`) delivered work
  and must publish a summary;
- a round that recorded a summary must be **covered** — a published review
  result at its own index or at a later recorded round;
- a **review-phase round** (`index > build_finish_round`) records a review, not
  new work, and owes no summary;
- every recorded round still needs at least one of the two, unchanged;
- `round_contract` is required **once per Run**, not per round. H:289
  overclaimed: only round 0's contract is scaffolded, by
  `scripts/setup-rlcr-loop.sh`, and every later one is agent-authored with no
  hook requiring it. Round 1 of `cancel-after-review`, `maxiter-derived` and
  `stop-derived` has a summary and a review result and no contract, while round
  1 of `complete-after-rework` and `path-cited-review-complete` has one — the
  runtime simply does not guarantee it. Every fixture in the corpus has
  `build_finish_round=0`, so the corpus contains no Run with more than one
  implementation round and therefore no evidence for a per-implementation-round
  contract rule either. Enforcing one would be a guess.

Both facts are projected into the Bundle — each `run.rounds[i]` carries `kind`
and `reviewed_by` — so a recipient reads the coverage relation instead of
reconstructing it, which is what #30 asked for.

The boundary is read from the **published bytes** of `.review-phase-started`,
which is ordinary hashed evidence, by the compiler and the validator alike. It
is read out of a Bundle rather than out of a trusted Run, so exactly one
complete, bounded declaration naming a recorded round is accepted. Absent,
withheld, malformed, duplicated, contradictory, oversized, or naming no recorded
round all give `kind: unknown`, and the older, stricter rule applies: the final
round needs both artifacts.

A boundary excuses a round from having to publish a summary, so an ambiguous one
must never be resolved in the producer's favour. Reading the first of several
declarations would let `build_finish_round=0` beside `build_finish_round=1`
quietly excuse round 1. Bounding the value keeps the parse total: CPython raises
on integer strings above 4300 digits, so an unbounded conversion turns a crafted
marker into an unhandled failure instead of a verdict. Not publishing the marker,
or publishing an ambiguous one, is never a licence.

## Considered Options

**Enforcing H:295 literally** — every round needs both artifacts — was the
other half of #30's choice. It rejects five real captured Runs, so taking it
would have meant re-capturing or reclassifying evidence to fit a rule. The
fixture is the fact; the rule is the thing under revision.

**Letting the producer declare each round's kind** in the manifest is simpler
and was rejected for the reason PR #29 already paid for once: the validator used
to read round coverage off `integrity.compile_warnings`, so deleting a warning
and re-hashing made the gap disappear. A declared `review_phase` is an exemption
from the summary requirement, so an unchecked declaration is a way to excuse a
missing summary. The validator re-derives both fields and rejects a Bundle whose
manifest disagrees.

**Deriving the boundary from the round artifacts alone** — treating any round
with a review result and no summary as review-phase — needs no marker, and is
unsound: deleting the last implementation round's summary would then relabel
that round as review-only and excuse the deletion. Reading `build_finish_round`
closes that, because the deleted round is still named as an implementation
round.

**Expressing the rule in the profile documents** would give each profile a new
per-round field. Rejected as unnecessary: both profiles already list
`round_summary` and `round_review_result` in `required_evidence_kinds`, and what
changes is the reading the validator gives those kinds, not the disclosure
policy the profile declares. Under [ADR-0006](0006-profile-documents-are-immutable-once-pinned.md)
a changed profile document is a new profile name, so this choice also avoids a
`local-v1`/`public-v2` cascade that would buy nothing.

## Consequences

- A Run that fixed every finding and passed a clean re-review no longer carries
  `open` findings forever. `clean-rereview-derived` — the dogfood's `csv-writer`
  with the record Loop now writes — resolves all four with `fix_round` and
  `re_review_ref`.
- The all-clear is written only when the whole review log carries no
  severity-marked token. The first version of this change wrote it whenever the
  50-line extraction window came back empty, which promoted a known detection
  gap into positive evidence: a `[P1]` outside the window took a Run from
  `changes_required` with the finding `open` to `accept` with it `resolved`.
  Extraction may keep its window; assertion may not.
- A new gap is reachable that was not before: an implementation round holding
  only a review result, its summary absent or withheld, is `incomplete` and
  cannot derive `accept`. Previously the per-round check inspected only the
  final round, so that Bundle verified `valid`.
- A Bundle whose final round is a review-phase round now verifies where it
  previously did not. This is a relaxation of `incomplete`, never of `invalid`,
  and it applies only where the published marker establishes the boundary.
- All ten existing Run fixtures satisfy the rule as captured; none was
  reclassified. The archived `pre-masking-public-v0` Bundle is unaffected — its
  single round carries all three artifacts — and Bundles written before these
  fields exist stay valid, since an absent field claims nothing.
- `run_id` is unchanged: its projection takes `round_indices` only
  (`proof/contract/ids.py`), so the new per-round fields do not move a Run's
  identity. `proof_id` covers them, and is recomputed per Bundle from the
  payload that Bundle carries.
- What this does not settle: whether every implementation round must carry a
  contract. A rule of "every implementation round needs one" would pass all ten
  fixtures today, and would still be a guess — every fixture has
  `build_finish_round=0`, so each has exactly one implementation round and the
  shape has never been exercised. Deciding it needs a captured Run with
  `build_finish_round >= 1`; tracked as issue #34.
