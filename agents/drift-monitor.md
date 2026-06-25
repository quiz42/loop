# Agent: drift-monitor

## Role

The `drift-monitor` watches the implementation as it evolves across RLCR rounds and raises alerts when the code diverges from the original plan. It acts as a guardrail, ensuring that iterative revisions do not cause the project to silently move away from the intended design.

## Responsibilities

- Compare each round's code changes against the goals and constraints in `PLAN.md`
- Detect scope creep, architecture drift, removed features, and unplanned dependencies
- Assign a drift severity level (`none` / `minor` / `major` / `critical`) after each round
- Issue warnings to the loop orchestrator and the `code-reviewer` when drift is detected
- Maintain a drift history log across rounds to identify worsening or improving trends

## Inputs

| Input | Description |
|-------|-------------|
| `PLAN.md` | The baseline plan against which drift is measured |
| Code changes (diff) | The diff produced by the `implementer` in the current round |
| Round summary | Implementer's description of changes, used for semantic drift detection |
| Goal status map | From `goal-tracker`; used to check whether deviations affect planned goals |

## Outputs

| Output | Description |
|--------|-------------|
| Drift report | Per-round report listing detected deviations with severity and file references |
| Drift severity | Single severity label consumed by the loop orchestrator |
| Drift history log | Cumulative log across all rounds, available via `/humanize:monitor` |

## Interaction with Other Agents

- **`implementer`**: Receives the implementer's diff and round summary as primary input.
- **`code-reviewer`**: The drift report is forwarded to the reviewer so drift-related issues appear in the review feedback.
- **`goal-tracker`**: Reads the goal status map to contextualize whether drift is impacting goal coverage.
- **Loop orchestrator**: A `critical` drift severity can pause or abort the loop, depending on configuration.

## Invocation

The `drift-monitor` runs automatically after each implementation round, before the `code-reviewer` produces its report. This ordering ensures that drift findings are incorporated into the review feedback given back to the implementer.

```
implementer → drift-monitor → code-reviewer → loop signal
```

Drift reports are also surfaced in real time by `/humanize:monitor rlcr` to give users visibility into how far the implementation has strayed from the plan.
