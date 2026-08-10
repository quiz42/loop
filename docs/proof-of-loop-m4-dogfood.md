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
| `token-bucket` | implementation | 3 | `complete` | 1 |
| `session-store` | `--skip-impl` review-only | 4 | `complete` | 4 over two rounds |
| `csv-writer` | `--skip-impl` review-only | 2 | `complete` | 4 in one round |

Six of the seven implementation Runs came back clean, so two review-only Runs
were added over deliberately flawed code to reach the finding lifecycle at all.
That is itself an observation: on small, well-specified tasks the loop rarely
produces a `[P0-9]` finding, so a corpus that only runs greenfield tasks barely
exercises the Findings view.

Two of the nine are now compatibility fixtures: `wrapped-ac-complete`
(`ini-parser`) and `path-cited-review-complete` (`csv-writer`). See
[`tests/fixtures/proof/runs/README.md`](../tests/fixtures/proof/runs/README.md).

## Observations

Eighteen Bundles: nine Runs under `local-v0` and the public profile of the
day. "Before" is the exporter as of `68c756b`, whose public profile was
`public-v0`; "after" is this branch, where the masking revision ships as
`public-v1` (ADR-0006) -- the After column reproduces under
`--profile public-v1`, and the corpus Bundles exported while masking briefly
lived in `public-v0` pin a hash no shipped document carries and are being
re-exported.

| Observation | Before | After |
| --- | --- | --- |
| Export success rate | 18/18 | 18/18 |
| `loop proof open` preflight success | 18/18 | 18/18 |
| Public-profile leakage incidents | **0** | **0** |
| Bundles verifying `valid` | 7/18 | 17/18 |
| Bundles with complete required evidence | 14/18 | 17/18 |
| Acceptance criteria judged `unverifiable` | 46/84 (55%) | 16/84 (19%) |
| Acceptance criteria carrying evidence references | 38/84 (45%) | 68/84 (81%) |
| Findings recorded across the corpus | 9 | 18 |
| Findings recorded in a public Bundle | **0** | 9 |
| Findings carrying a fix or waiver link | 3/9 | 6/18 |

Leakage stayed at its target of zero in every Bundle, measured independently of
the exporter's own claim by rescanning the written bytes.

Both finding rows count each Run twice, once per profile, because a public
Bundle now reports the same findings its local counterpart does. The one Run
that links any of them still links three, and observation 4 explains why that
number cannot yet be higher. The single Bundle that remains `incomplete` is
`token-bucket` under the public profile, for the reason in observation 3.

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

Fixed in two parts.

`public-v1` (the revision of `public-v0`; the old profile is frozen per
ADR-0006) publishes a path-citing review result **masked** rather than
withholding it: the absolute home paths are replaced with a placeholder, the
item is declared `status: "masked"`, and a second hash covers the bytes the
Bundle carries so tamper detection still bites on what a recipient receives.
Only `round_review_result` may be masked, because every other required kind
feeds structured projections into `proof.json`. The trade-off, and the two
options that were rejected, are recorded in
[ADR-0004](adr/0004-masked-publication-of-path-bearing-evidence.md); the cost is
that only a `local-v0` Bundle of the same Run can show the masking was faithful.

Where an item genuinely is not published -- omitted, or over `max_item_bytes` --
the findings it raised are still recorded, as `unverifiable` and never
`resolved`: withheld evidence may show that a problem existed, never that one
was fixed. The Explorer distinguishes "none recorded" from "none shown here",
and gives a masked item its own treatment so it cannot be read as withheld.

`token-bucket` is the remaining gap, and it is the case the kind restriction
excludes: the path is in its **Goal Tracker**, so that item is still omitted and
its public Bundle still carries zero acceptance criteria and verifies
`incomplete`. It is the one Bundle of eighteen that does not verify `valid`.

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

Fixed, together with the rule it was blocked on. `detect_review_issues` now
writes a fact-only `round-N-review-result.md` on a clean pass — the round, the
reviewed base and commit, and that no severity-marked finding was reported. The
cache log is not copied: it is hundreds of lines of prompt and exec trace with
absolute paths in it, and none of that is what closes a finding.

Recording it creates a round holding a review result and no builder summary,
which the round-evidence rule counted as missing evidence — the reason this
could not be done on its own. [ADR-0007](adr/0007-round-evidence-is-per-round-with-review-carried-forward.md)
settles that rule: evidence is owed per round, a round after the Run's
`build_finish_round` is a Review-Phase Round and owes no summary, and a round's
summarized work is covered by a review at its own index or a later one.

**The corpus numbers above do not move, and should not.** These nine Runs were
captured before Loop recorded a clean review, so the artifact is simply not in
them; re-exporting them under this change reproduces the After column exactly —
18/18 exported, 17/18 `valid`, zero leakage, the same 6/18 linkage. Writing the
missing record into a captured Run to improve the figure would be manufacturing
the evidence the whole layer exists to check. The gain is demonstrated instead
on `clean-rereview-derived`, the `csv-writer` Run kept as a fixture and labelled
a derivative, with the record Loop now writes appended: all four of its findings
resolve, each carrying `fix_round` and `re_review_ref`, under both profiles.
Runs recorded from here on carry it for real.

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
python3 scripts/proof-export.py --run <run-dir> --profile public-v1 --out <bundle>
python3 scripts/proof-verify.py <bundle>            # 0 valid, 2 incomplete, 3 invalid
python3 scripts/proof-open.py   <bundle>
```

The per-Bundle counts above are read out of `proof.json` plus the written bytes,
so a third party can recompute them from a received Bundle alone: leakage by
rescanning every file for `/Users/<name>` or `/home/<name>`, and every other
number from `verdict.per_ac`, `findings`, `evidence` and
`integrity.compile_warnings`.

## Not done in this milestone

**Observation 3's remaining half, a path-bearing Goal Tracker.** Masking is
restricted to `round_review_result` because every other required kind feeds
structured projections into `proof.json`: the Goal Tracker gives criterion text
and its `text_sha256`, deferral rows copied verbatim, and plan evolution.
Masking those means either the manifest asserts facts derived from bytes it did
not publish, or the Adapter re-parses published bytes -- a pipeline inversion,
and the kind of Compiler/Validator split that has cost this repo review rounds
before. Until that is settled, a Run like `token-bucket` still exports a public
Bundle with no acceptance criteria.

**Relativizing paths in Loop itself** remains available and is not needed by
anything here. It would keep future review results free of absolute paths so
masking rarely fires, but it rewrites the reviewer's output at capture time
without leaving a trace, which is why ADR-0004 did not adopt it as the primary
fix.
