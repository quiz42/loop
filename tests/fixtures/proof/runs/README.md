# Proof Run fixtures

These directories are complete source Loop Run artifacts for the Proof of Loop
M0 compatibility corpus. They are not exported Proof Bundles: future compiler
and validator tests copy them and create any tampered Bundles programmatically.

| Fixture | Origin | Terminal State |
| --- | --- | --- |
| `clean-complete` | Real Claude+Codex RLCR Run | `complete` |
| `noncontiguous-ac-complete` | Synthetic complete Run with explicit AC1, AC2, AC4, and AC5 labels | `complete` |
| `complete-after-rework` | Real Claude+Codex RLCR Run with Codex findings resolved in a follow-up round | `complete` |
| `cancel-after-review` | Real Claude+Codex RLCR Run deliberately cancelled after Codex review | `cancel` |
| `maxiter-derived` | Mechanical derivative of `cancel-after-review` | `maxiter` |
| `stop-derived` | Mechanical derivative of `cancel-after-review` | `stop` |
| `unexpected-derived` | Mechanical derivative of `clean-complete` | `unexpected` |
| `legacy-pre-d17` | Mechanical derivative of `clean-complete` with D17 recorder facts removed | `complete` |
| `wrapped-ac-complete` | Real Claude+Codex RLCR Run from the M4 dogfood | `complete` |
| `path-cited-review-complete` | Real Claude+Codex RLCR Run from the M4 dogfood, in `--skip-impl` review-only mode | `complete` |
| `clean-rereview-derived` | Mechanical derivative of `path-cited-review-complete` | `complete` |

The three real Runs are kept whole, including prompt and review-prompt files.
Their raw source paths are intentional input to later public-profile tests --
`public-v1` masking and frozen `public-v0` omission alike; this corpus itself
is not a public-profile export.

`noncontiguous-ac-complete` is a minimal synthetic Run used to ensure explicit
acceptance-criterion labels, rather than list positions, remain stable IDs.

`legacy-pre-d17/complete-state.md` starts with a header explaining the
simulated pre-D17 recorder gap. Do not remove that comment or restore its
`reviewed_*`, `head_commit`, or `ended_at` fields.

The two M4 dogfood Runs were added because the original corpus, written from
short hand-authored plans, never produced two shapes that every real Run does.
Both are covered by `tests/test-proof-verdict.sh`; keep the properties below
intact or those assertions stop testing anything.

- `wrapped-ac-complete` has hard-wrapped acceptance criteria (a criterion
  spanning several lines) and a `Completed and Verified` row whose AC cell is
  the range `AC1-AC5`.
- `path-cited-review-complete` is a review-only Run whose
  `round-1-review-result.md` carries four `[P0-9]` findings and cites the files
  it faults by absolute path. `public-v1` publishes that review masked, which
  the masked-publication tests assert; the withheld-findings property the Run
  was captured for is still exercised by truncating the same review past
  `max_item_bytes`.

## Round evidence

Every Run here satisfies the round-evidence rule as captured (ADR-0007); none
was reshaped to fit it. Two shapes are worth naming because they look like gaps
and are not:

- **An implementation round with no review result of its own.** Round 0 of
  `cancel-after-review`, `complete-after-rework`, `maxiter-derived`,
  `stop-derived` and `path-cited-review-complete` has a summary and no review
  result. `codex review` reads the cumulative diff from the Run's base commit,
  so round 1's review covers round 0's work; the round is reviewed, just not in
  its own index. Applying spec H:295 literally would have rejected
  `cancel-after-review`, a real captured Run, which is why the rule is written
  as coverage rather than as one review per round.
- **A round with no contract.** Round 1 of `cancel-after-review`,
  `maxiter-derived` and `stop-derived` has both a summary and a review result
  but no contract, while round 1 of `complete-after-rework` and
  `path-cited-review-complete` does have one. Only round 0's contract is
  scaffolded by `setup-rlcr-loop.sh`; the rest are agent-authored and no hook
  requires them. `round_contract` is therefore required once per Run, not per
  round.

`clean-rereview-derived` is `path-cited-review-complete` plus the
`round-2-review-result.md` that Loop now writes when a re-review comes back
clean. It exists because the base Run is the M4 dogfood's `csv-writer`, the Run
that reached `complete` through a clean re-review and left all four of its
findings `open` forever (issue #33). The pair is the before and after of one
real Run: keep the base fixture's four `open` findings and this one's four
`resolved` findings carrying `fix_round` 2, or the assertions in
`tests/test-proof-verdict.sh` stop testing anything. Its round 2 has a review
result and no summary — the review-phase shape whose evidence rule ADR-0007
settles.
