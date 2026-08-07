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

The three real Runs are kept whole, including prompt and review-prompt files.
Their raw source paths are intentional input to later `public-v0` omission
tests; this corpus itself is not a public-profile export.

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
  it faults by absolute path, so `public-v0` withholds that review result. It
  is the corpus's only Run where a public Bundle must still report findings
  whose evidence it does not carry.
