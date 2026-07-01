# Agent: code-reviewer

## Role

The `code-reviewer` is a Codex-powered agent that performs code review within the RLCR (Ralph-Loop with Codex Review) loop. After each implementation round by the `implementer` agent, the `code-reviewer` evaluates the changes, identifies issues, and produces structured feedback that drives the next iteration.

## Responsibilities

- Review code changes produced by the `implementer` agent against the active plan
- Check for correctness, style, security concerns, and adherence to the plan goals
- Produce a structured review report with actionable feedback
- Signal loop termination when all acceptance criteria are met or when issues are unresolvable
- Enforce consistency with previously agreed-upon architecture and patterns

## Inputs

| Input | Description |
|-------|-------------|
| Diff / changed files | The code changes produced in the current iteration |
| `PLAN.md` | The active implementation plan defining goals and acceptance criteria |
| Previous review reports | History of prior rounds to detect repeated issues or regressions |
| Codex model configuration | Model name (`--codex-model`) and effort level (`--codex-effort`) passed at loop start |

## Outputs

| Output | Description |
|--------|-------------|
| Review report | Structured markdown report listing issues by severity (blocking / non-blocking) |
| Loop signal | `APPROVED`, `NEEDS_REVISION`, or `BLOCKED` — consumed by the loop orchestrator |
| Annotations | Inline comments on specific files/lines when applicable |

## Interaction with Other Agents

- **`implementer`**: Receives review output and uses it as the instruction set for the next implementation round.
- **`goal-tracker`**: Shares the review report so the tracker can update goal completion status.
- **`drift-monitor`**: Notifies the drift monitor when review findings suggest the implementation has diverged from the plan.
- **Loop orchestrator** (`start-rlcr-loop`): Returns the loop signal that determines whether to continue, retry, or halt.

## Invocation

The `code-reviewer` is invoked automatically by the RLCR loop at the end of every implementation round. It is not invoked directly by the user. The loop sequence is:

```
implementer → code-reviewer → (loop signal)
                    ↓ NEEDS_REVISION
              implementer (next round)
                    ↓ APPROVED
              loop terminates
```

The Codex model used is controlled by `--codex-model` (default: `gpt-5.5`) and the effort level by `--codex-effort` (default: `high`), both supplied to `/loop:start-rlcr-loop`.
