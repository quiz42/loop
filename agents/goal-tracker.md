# Agent: goal-tracker

## Role

The `goal-tracker` monitors and maintains the completion state of every goal defined in the active `PLAN.md`. It provides a live view of what has been done, what remains, and whether the loop is converging toward completion.

## Responsibilities

- Parse `PLAN.md` to extract goals, tasks, and acceptance criteria at loop start
- Update goal status after each implementation round based on the round summary and review report
- Detect when all goals are satisfied and signal the loop orchestrator that the work is done
- Persist goal state between rounds so partial progress survives interruptions
- Surface a human-readable progress summary on demand (used by `/humanize:monitor`)

## Inputs

| Input | Description |
|-------|-------------|
| `PLAN.md` | Source of truth for goals and acceptance criteria |
| Round summary | Short description from the `implementer` of what changed in the round |
| Review report | Output from the `code-reviewer`, used to determine which goals were verified |
| `--track-plan-file` flag | When set, writes goal state back to the plan file after each round |

## Outputs

| Output | Description |
|--------|-------------|
| Goal status map | Machine-readable map of goal → status (`pending` / `in-progress` / `done` / `blocked`) |
| Progress report | Human-readable summary of completion percentage and remaining work |
| Completion signal | `ALL_GOALS_MET` signal sent to the loop orchestrator when every goal is satisfied |

## Interaction with Other Agents

- **`implementer`**: Receives the round summary to update in-progress and completed goals.
- **`code-reviewer`**: Uses the review report to mark goals as verified or still failing.
- **`drift-monitor`**: Shares the goal status map; the drift monitor checks whether in-progress goals are still aligned with the plan.
- **Loop orchestrator**: Receives the `ALL_GOALS_MET` signal to terminate the loop gracefully.

## Invocation

The `goal-tracker` runs passively throughout the RLCR loop — it is updated at the end of each round after both the implementer and reviewer have completed their work. It is also queried directly by the `/humanize:monitor` command to produce live status output.

When `--track-plan-file` is passed to `/humanize:start-rlcr-loop`, the goal-tracker writes updated checkbox state back into `PLAN.md` so progress is visible in the file itself.
