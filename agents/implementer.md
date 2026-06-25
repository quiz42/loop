# Agent: implementer

## Role

The `implementer` is a Claude-powered agent that performs the actual code implementation within the RLCR loop. It reads the active plan and, when revisiting, incorporates feedback from the `code-reviewer` to produce improved code changes each round.

## Responsibilities

- Translate plan goals and tasks into working code changes
- Apply reviewer feedback from the previous round to correct issues and address blocking comments
- Commit or stage changes at the end of each round (optionally pushing via `--push-every-round`)
- Maintain context across rounds to avoid regressing already-approved work
- Respect architectural decisions and patterns established in earlier rounds

## Inputs

| Input | Description |
|-------|-------------|
| `PLAN.md` | The active implementation plan with goals, tasks, and acceptance criteria |
| Review report | Structured feedback from the `code-reviewer` (empty on the first round) |
| Codebase state | Current state of the repository at the start of each round |
| Loop configuration | Options such as `--agent-teams`, `--max-iterations`, and `--push-every-round` |

## Outputs

| Output | Description |
|--------|-------------|
| Code changes | New or modified files constituting the implementation for this round |
| Round summary | Brief description of what was changed and why, used by `goal-tracker` and `drift-monitor` |

## Interaction with Other Agents

- **`code-reviewer`**: Hands off completed code changes for review; receives the reviewer's report as input for the next round.
- **`goal-tracker`**: Provides the round summary so goal completion can be updated.
- **`drift-monitor`**: The drift monitor observes the implementer's output and raises alerts if changes deviate from the plan.
- **Loop orchestrator** (`start-rlcr-loop`): Receives the loop signal from the reviewer and triggers the next implementer round when `NEEDS_REVISION`.

## Invocation

The `implementer` is invoked automatically at the start of every RLCR loop round. On the first round it works from the plan alone; on subsequent rounds it also works from the reviewer's feedback. The loop sequence is:

```
[round start] → implementer → code-reviewer → [loop signal]
                     ↑ NEEDS_REVISION ──────────────┘
```

When `--agent-teams` is enabled, multiple implementer sub-agents may work on independent plan sections in parallel before their outputs are merged and reviewed together.
