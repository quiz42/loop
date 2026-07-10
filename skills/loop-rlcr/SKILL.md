---
name: loop-rlcr
description: Start, cancel, and monitor the RLCR iterative development loop
---

# Loop RLCR

Run the RLCR (Ralph-Loop with Codex Review) loop for iterative AI-driven development. Each iteration applies changes according to the plan, then submits them for Codex review before advancing.

## Commands

### start-rlcr-loop

Start the RLCR loop against a plan file.

```
python3 scripts/loop.py start-rlcr-loop [PLAN.md] [OPTIONS]
```

| Option | Description |
|---|---|
| `PLAN.md` | Plan file to execute; required unless `--skip-impl` is used |
| `--codex-model MODEL` | Codex model for review rounds (default: gpt-5.1) |
| `--codex-effort high` | Use high reasoning effort for Codex review |
| `--max-iterations N` | Maximum loop iterations before stopping (default: 42) |
| `--agent-teams` | Enable multi-agent team mode for parallel execution |
| `--track-plan-file` | Require the plan file to be tracked and clean before loop setup |
| `--push-every-round` | Push commits to remote after each completed round |

### cancel-rlcr-loop

Stop a running RLCR loop gracefully.

```
python3 scripts/loop.py cancel-rlcr-loop [OPTIONS]
```

| Option | Description |
|---|---|
| `--reason REASON` | Human-readable reason for cancellation output |
| `--force` | Cancel even when the loop is in finalize phase |

### monitor rlcr

Watch the status and output of a running RLCR loop.

```
python3 scripts/loop.py monitor rlcr [--once]
```

| Option | Description |
|---|---|
| `--once` | Print current status once and exit instead of tailing |

### monitor codex / monitor gemini

Watch the output of a running Codex or Gemini subprocess.

```
python3 scripts/loop.py monitor codex [--once]
python3 scripts/loop.py monitor gemini [--once]
```

## Examples

Start a loop with default settings:
```
python3 scripts/loop.py start-rlcr-loop plan.md
```

Start with high-effort Codex review and push after each round:
```
python3 scripts/loop.py start-rlcr-loop plan.md --codex-effort high --push-every-round
```

Start with agent teams and a 10-iteration cap:
```
python3 scripts/loop.py start-rlcr-loop plan.md --agent-teams --max-iterations 10
```

Monitor the loop in real time:
```
python3 scripts/loop.py monitor rlcr
```

Cancel a running loop with a reason:
```
python3 scripts/loop.py cancel-rlcr-loop --reason "Pivoting plan direction"
```

## Notes

- Defaults are shown in the command option table above.
- `--agent-teams` is disabled by default; enable for complex plans that benefit from parallel agents.
- Use `--track-plan-file` when the plan should be treated as a tracked git input.
- The loop stops automatically when all plan steps pass Codex review or when `--max-iterations` is reached.
