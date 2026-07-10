# Command: /loop:start-rlcr-loop

Start an RLCR (Ralph-Loop with Codex Review) iterative development loop. Claude implements the plan, Codex reviews the result, and the cycle repeats until all goals are met or the iteration limit is reached.

## Usage

```
/loop:start-rlcr-loop PLAN.md [options]
```

Internally runs:

```
loop start-rlcr-loop PLAN.md [--codex-model MODEL] [--codex-effort LEVEL] \
  [--max-iterations N] [--agent-teams] [--track-plan-file] [--push-every-round]
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `PLAN.md` | Yes | Path to the implementation plan file that defines goals, tasks, and acceptance criteria |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--codex-model MODEL` | `gpt-5.1` | Codex model recorded for review rounds |
| `--codex-effort LEVEL` | `high` | Effort level recorded for Codex review (`low`, `medium`, `high`, `xhigh`) |
| `--max-iterations N` | `42` | Maximum number of implement→review rounds before the loop is forcibly stopped |
| `--codex-timeout SECONDS` | `5400` | Review timeout recorded for Codex review rounds |
| `--base-branch BRANCH` | auto | Local branch used as the review base |
| `--agent-teams` | off | Enable parallel sub-agent teams so independent plan sections are implemented concurrently |
| `--track-plan-file` | off | Require the plan file to be tracked and clean before loop setup |
| `--push-every-round` | off | Push changes to the remote branch at the end of each round |
| `--skip-impl` | off | Start in review-only mode without a plan file |
| `--privacy` | off | Disable methodology-analysis phase metadata |

## What It Does

1. Validates that the project is a git repository with a clean working tree.
2. Validates the plan file and base branch.
3. Creates `.loop/rlcr/<timestamp>/` with `state.md`, `goal-tracker.md`, `round-0-prompt.md`, `round-0-summary.md`, and `round-0-contract.md`.
4. Copies the plan into the loop session and writes `.loop/.pending-session-id`.
5. Records review model, effort, timeout, iteration limit, branch, and plan metadata for the loop hooks.

## Example Usage

```
# Minimal — start a loop with defaults
/loop:start-rlcr-loop PLAN.md

# Use a specific Codex model with agent teams and auto-push
/loop:start-rlcr-loop PLAN.md --codex-model gpt-5.1 --codex-effort high \
  --agent-teams --push-every-round

# Cap iterations and track progress in the plan file
/loop:start-rlcr-loop PLAN.md --max-iterations 10 --track-plan-file
```

## Expected Output

```
RLCR loop initialized.
Loop directory: /path/to/project/.loop/rlcr/2026-07-10_12-00-00
State file: /path/to/project/.loop/rlcr/2026-07-10_12-00-00/state.md
Prompt file: /path/to/project/.loop/rlcr/2026-07-10_12-00-00/round-0-prompt.md
```

When `--track-plan-file` is set, the setup step verifies that `PLAN.md` is tracked by git and has no local modifications before the loop starts.
