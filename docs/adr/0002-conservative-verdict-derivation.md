# Delivery Verdict uses conservative derivation: structured facts only, never an automatic reject

When the MVP's Evidence Compiler derives per-AC status and the Delivery Verdict from Loop artifacts, it trusts only structured signals (section moves in `goal-tracker.md`, `[P0]`-`[P9]` finding markers, `COMPLETE` / `Mainline Progress Verdict` markers, Terminal State). It performs no heuristic parsing of natural-language review text; anything it cannot parse is marked `unverifiable`. The Compiler also never emits `reject` automatically — that value stays in the schema enum, reserved for a future manual acknowledgment or a structured Reviewer sidecar.

## Considered Options

Aggressive parsing (extracting per-AC conclusions from raw review text via regex or text matching, paired with a parser confidence score) was rejected: its failure mode is "looks all green but is actually a parsing hallucination", and the damage that does to product trust far outweighs a higher count of `unverifiable`. Heuristic recognition of `reject` (for example, maxiter + circuit breaker → reject) was rejected for the same reason — `reject` carries the heaviest social consequences of the four states, so a false positive is the most expensive, while facts such as maxiter and the circuit breaker are already presented honestly through Terminal State and the Timeline.

## Consequences

- The share of `unverifiable` ACs will run high during the MVP. This is a deliberate trade-off; the right way to bring it down is the structured test-result / Reviewer-verdict sidecars in P1, not looser parsing.
- AC-4 (zero evidence must never yield an automatic `met`) and AC-9 (honest status) are direct corollaries of this decision, and both implementation and tests should treat them as the yardstick.
