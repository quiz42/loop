# Command: /humanize:start-rlcr-loop

Start an RLCR (Ralph-Loop with Codex Review) iterative development loop. Claude implements the plan, Codex reviews the result, and the cycle repeats until all goals are met or the iteration limit is reached.

## Usage

```
/humanize:start-rlcr-loop PLAN.md [options]
```

Internally runs:

```
humanize start-rlcr-loop PLAN.md [--codex-model MODEL] [--codex-effort LEVEL] \
  [--max-iterations N] [--agent-teams] [--track-plan-file] [--push-every-round]
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `PLAN.md` | Yes | Path to the implementation plan file that defines goals, tasks, and acceptance criteria |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--codex-model MODEL` | `gpt-5.5` | Codex model used by the `code-reviewer` agent for reviewing each round |
| `--codex-effort LEVEL` | `high` | Effort level passed to the Codex reviewer (`low`, `medium`, `high`) |
| `--max-iterations N` | `42` | Maximum number of implement→review rounds before the loop is forcibly stopped |
| `--agent-teams` | off | Enable parallel sub-agent teams so independent plan sections are implemented concurrently |
| `--track-plan-file` | off | Write goal completion state back into `PLAN.md` after every round (updates checkboxes) |
| `--push-every-round` | off | Push changes to the remote branch at the end of each round |

## What It Does

1. Parses `PLAN.md` to extract goals and acceptance criteria.
2. Starts the `goal-tracker` and `drift-monitor` agents.
3. Runs the RLCR loop:
   - **Implement**: the `implementer` agent writes or modifies code.
   - **Monitor drift**: the `drift-monitor` checks changes against the plan.
   - **Review**: the `code-reviewer` (Codex) evaluates the diff and returns `APPROVED`, `NEEDS_REVISION`, or `BLOCKED`.
   - If `NEEDS_REVISION`, the review report is fed back to the implementer for the next round.
4. Terminates when the reviewer signals `APPROVED`, the `goal-tracker` signals `ALL_GOALS_MET`, or `--max-iterations` is reached.

## Example Usage

```
# Minimal — start a loop with defaults
/humanize:start-rlcr-loop PLAN.md

# Use a specific Codex model with agent teams and auto-push
/humanize:start-rlcr-loop PLAN.md --codex-model gpt-5.5 --codex-effort high \
  --agent-teams --push-every-round

# Cap iterations and track progress in the plan file
/humanize:start-rlcr-loop PLAN.md --max-iterations 10 --track-plan-file
```

## Expected Output

```
[humanize] Starting RLCR loop from PLAN.md
[humanize] Goals detected: 7
[humanize] Round 1 — implementing...
[humanize] Round 1 — reviewing (codex/gpt-5.5, effort=high)...
[humanize] Round 1 — review result: NEEDS_REVISION (3 blocking issues)
[humanize] Round 2 — implementing...
[humanize] Round 2 — reviewing...
[humanize] Round 2 — review result: APPROVED
[humanize] All goals met. Loop complete after 2 rounds.
```

When `--track-plan-file` is set, `PLAN.md` is updated with `[x]` checkboxes as goals are completed.
