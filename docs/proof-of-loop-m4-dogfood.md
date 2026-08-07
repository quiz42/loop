# Proof of Loop M4: dogfood observations

> Date: 2026-08-08
> Scope: Milestone 4 of [`proof-of-loop-mvp-spec.md`](proof-of-loop-mvp-spec.md) and issue #12.
> Corpus: nine real Claude+Codex RLCR Runs, exported under both profiles, verified and preflight-opened.

## What was run

Nine tasks were taken end to end through `loop proof export` -> `verify` ->
`open`. Each is an ordinary public programming task in its own scratch Git
repository, driven headlessly by the plugin's own hooks; none was authored to
suit the Proof layer, which is the point.

| Task | Mode | Rounds | Terminal state | Code-review findings |
| --- | --- | --- | --- | --- |
| `semver-compare` | implementation | 2 | `complete` | none |
| `ini-parser` | implementation | 1 | `complete` | none |
| `csv-column-stats` | implementation | 1 | `complete` | none |
| `retry-backoff` | implementation | 1 | `complete` | none |
| `glob-match` | implementation | 1 | `complete` | none |
| `roman-numeral` | implementation | 1 | `complete` | none |
| `token-bucket` | implementation | 3 | `complete` | none |
| `session-store` | `--skip-impl` review-only | 4 | `complete` | 4 over two rounds |
| `csv-writer` | `--skip-impl` review-only | 2 | `complete` | 4 in one round |

Seven implementation Runs came back clean, so two review-only Runs were added
over deliberately flawed code to reach the finding lifecycle at all. That is
itself an observation: on small, well-specified tasks the loop rarely produces
a `[P0-9]` finding, so a corpus that only runs greenfield tasks never exercises
the Findings view.

Two of the nine are now compatibility fixtures: `wrapped-ac-complete`
(`ini-parser`) and `path-cited-review-complete` (`csv-writer`). See
[`tests/fixtures/proof/runs/README.md`](../tests/fixtures/proof/runs/README.md).

## Observations

Eighteen Bundles: nine Runs under `local-v0` and `public-v0`. "Before" is the
exporter as of `68c756b`; "after" is this branch.

| Observation | Before | After |
| --- | --- | --- |
| Export success rate | 18/18 | 18/18 |
| `loop proof open` preflight success | 18/18 | 18/18 |
| Public-profile leakage incidents | **0** | **0** |
| Bundles verifying `valid` | 7/18 | 14/18 |
| Bundles with complete required evidence | 14/18 | 14/18 |
| Acceptance criteria judged `unverifiable` | 46/84 (55%) | 16/84 (19%) |
| Acceptance criteria carrying evidence references | 38/84 (45%) | 68/84 (81%) |
| Findings recorded across the corpus | 9 | 18 |
| Findings recorded in a public Bundle | **0** | 9 |
| Findings carrying a fix or waiver link | 3/9 | 3/18 |

Leakage stayed at its target of zero in every Bundle, measured independently of
the exporter's own claim by rescanning the written bytes.

### 1. A wrapped acceptance criterion lost everything after its first line

Every real plan hard-wraps. The Goal Tracker's IMMUTABLE section therefore holds
criteria spanning several lines, and the parser read only the bullet line: the
criterion text stopped mid-sentence and `text_sha256` committed to the fragment.
All nine Runs were affected. The Acceptance Matrix -- the maintainer's primary
artifact -- showed truncated criteria in every Bundle.

Fixed: continuation lines are folded back into the criterion.

### 2. An `AC1-AC5` range cost four Runs their verdict

Four of the nine Runs wrote a range into the `Completed and Verified` AC column
rather than listing each criterion. `AC1-AC5` matched neither the single
reference form nor the well-formed shape, so the row resolved to `ac-5` alone
and reported a malformed reference -- and a malformed reference invalidates the
AC mapping, which makes the whole delivery `unverifiable`. Three or four
genuinely verified criteria per Run fell back to `unverifiable` with it.

This is the single largest contributor to the 55% `unverifiable` share. A range
states which criteria it names as exactly as a comma-separated list does, so
reading it stays inside ADR-0002; a descending or absurdly wide range is still
reported as malformed.

Fixed: `ACn-ACm` and `ACn-m` expand to the criteria they name.

### 3. `public-v0` withheld every review result that reported a finding

`codex review` cites the file it faults by absolute path. Over the eighteen
independent review results in the nine dogfood Runs and the real golden Runs,
**all seven that reported a `[P0-9]` finding contained an absolute home path**,
so `public-v0`'s `absolute-path` omission rule withheld all seven. Clean
reviews carry a path only sometimes (3 of 11), so the rule bites hardest
exactly where the evidence matters most.

Two consequences, both visible to a maintainer:

- the Bundle's `findings` array was empty, and the Explorer said "No structured
  findings were recorded for this Run" -- the opposite of what happened;
- `round_review_result` is required evidence, so integrity fell to `incomplete`
  and `loop proof verify` exited 2.

`token-bucket` is the worst case and is not a corner case: its `goal-tracker.md`
also contained an absolute path, so the public Bundle carries **zero acceptance
criteria**, no summaries, no finalize summary, and 14 of its 21 evidence items
omitted. A maintainer receiving it sees an empty Acceptance Matrix for a Run
that completed with six criteria.

Partly fixed. A withheld review result now still reports the findings it
raised, as `unverifiable` and never `resolved`: withheld evidence may show that
a problem existed, never that one was fixed. The Explorer now distinguishes
"none recorded" from "none shown here". **The over-redaction itself is not
fixed** -- see "Not done" below.

### 4. Finding-to-fix linkage only closes while problems remain

`session-store` is the corpus's first real resolved-with-re-review shape: three
of its four findings carry `fix_round` and `re_review_ref`. It got there because
each of its re-reviews still found something, and `detect_review_issues` writes
`round-N-review-result.md` **only when it finds a `[P0-9]` marker**.

When a re-review comes back clean it writes nothing into the Run directory. Its
verdict ("No actionable correctness issues were found in the diff") goes to
`$XDG_CACHE_HOME/loop/<project>/<timestamp>/round-N-codex-review.log`, outside
the Run, deliberately so agents do not read it. `csv-writer` is exactly that
shape: it reached `complete` after a clean re-review, and all four of its
findings remain `open` forever, because the one artifact that would close them
was produced and discarded.

So the Proof layer is not being conservative here; it has no evidence to be
conservative about. This is the root cause of the finding-to-fix linkage rate,
and it is a Loop-side artifact gap, not a derivation gap.

### 5. An interrupted Run cannot be resumed by a new session

Every Run is pinned to the `session_id` in its state frontmatter, and
`find_active_loop` returns nothing for any other session. When the driving
session died mid-Run, six Runs froze in Finalize: a new session's Stop hook
declined to adopt them, exited 0, and the loop simply stopped. Recovery required
hand-clearing `session_id` in the state file, after which every Run finished
normally. There is no supported recovery path for a Run whose session is gone.

Not a Proof-layer issue, recorded because it costs a real Run.

## Reproducing the observations

```bash
python3 scripts/proof-export.py --run <run-dir> --profile public-v0 --out <bundle>
python3 scripts/proof-verify.py <bundle>            # 0 valid, 2 incomplete, 3 invalid
python3 scripts/proof-open.py   <bundle>
```

The per-Bundle counts above are read out of `proof.json` plus the written bytes,
so a third party can recompute them from a received Bundle alone: leakage by
rescanning every file for `/Users/<name>` or `/home/<name>`, and every other
number from `verdict.per_ac`, `findings`, `evidence` and
`integrity.compile_warnings`.

## Not done in this milestone

Two of the findings above need a decision that belongs to the maintainer rather
than to this change, so each is filed with its evidence instead of guessed at.
Issue #12's second acceptance criterion -- revising `public-v0` and the schema
-- is therefore **not** met here.

**Observation 3, the over-redaction.** Keeping a public Bundle's review result
readable requires one of two changes, and both go beyond a fix:

1. *Publish a path-normalized copy.* Add `secret_scan.redact_on` to the profile
   schema and a `redacted` evidence status carrying both the source `sha256`
   and a `redacted_sha256` over the published bytes. Already-distributed
   Bundles keep verifying, since none carries the new status. The cost is real
   and must be stated in the UI: a redacted item's bytes are no longer
   byte-identical to the source, so a recipient can verify the published bytes
   are intact but can only confirm the redaction was faithful against the
   `local-v0` Bundle. This contradicts spec section C's "a profile never
   rewrites file content", which exists to prevent exactly that ambiguity.
2. *Stop writing absolute paths into Run artifacts.* Relativize paths against
   the project root when the review result is written. The Proof contract is
   untouched and evidence stays verbatim, but only future Runs benefit.

Option 2 is the better engineering answer and option 1 is the only one that
helps the Runs already on disk. Both are worth doing; neither should be picked
without the maintainer.

**Observation 4, the discarded clean re-review.** Writing
`round-N-review-result.md` on a clean pass would close the finding lifecycle,
but it also adds round N to `run.rounds`, and `round_coverage_gaps` requires a
final round to carry both a summary and a review result. A review-phase round
has no builder summary, so the rule needs a matching refinement -- which is the
question issue #30 already holds open. The dogfood evidence for it is above.
