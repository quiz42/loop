# Proof Run fixtures

These directories are complete source Loop Run artifacts for the Proof of Loop
M0 compatibility corpus. They are not exported Proof Bundles: future compiler
and validator tests copy them and create any tampered Bundles programmatically.

| Fixture | Origin | Terminal State |
| --- | --- | --- |
| `clean-complete` | Real Claude+Codex RLCR Run | `complete` |
| `complete-after-rework` | Real Claude+Codex RLCR Run with Codex findings resolved in a follow-up round | `complete` |
| `cancel-after-review` | Real Claude+Codex RLCR Run deliberately cancelled after Codex review | `cancel` |
| `maxiter-derived` | Mechanical derivative of `cancel-after-review` | `maxiter` |
| `stop-derived` | Mechanical derivative of `cancel-after-review` | `stop` |
| `unexpected-derived` | Mechanical derivative of `clean-complete` | `unexpected` |
| `legacy-pre-d17` | Mechanical derivative of `clean-complete` with D17 recorder facts removed | `complete` |

The three real Runs are kept whole, including prompt and review-prompt files.
Their raw source paths are intentional input to later `public-v0` omission
tests; this corpus itself is not a public-profile export.

`legacy-pre-d17/complete-state.md` starts with a header explaining the
simulated pre-D17 recorder gap. Do not remove that comment or restore its
`reviewed_*`, `head_commit`, or `ended_at` fields.
