---
name: loop
description: Main loop plugin skill covering all loop commands
---

# Loop

The loop plugin drives iterative AI-assisted development through a structured workflow: generate a plan, refine it, then run the RLCR (Ralph-Loop with Codex Review) loop until all plan steps pass automated review.

## Commands Overview

| Command | Purpose |
|---|---|
| `gen-plan` | Generate a structured plan from an idea file |
| `start-rlcr-loop` | Start the iterative RLCR development loop |
| `cancel-rlcr-loop` | Stop a running loop |
| `monitor rlcr` | Watch loop status in real time |
| `monitor codex` | Watch Codex subprocess output |
| `monitor gemini` | Watch Gemini subprocess output |

## Usage

```
python3 scripts/loop.py COMMAND [OPTIONS]
```

## Commands

### gen-plan

Generate a structured implementation plan from an idea file.

```
python3 scripts/loop.py gen-plan [--input IDEA.md] [--output plan.md] [--title TITLE]
```

### start-rlcr-loop

Start the RLCR loop to iteratively implement and review a plan.

```
python3 scripts/loop.py start-rlcr-loop [PLAN.md] [--codex-model MODEL] [--codex-effort high] [--max-iterations 42] [--agent-teams] [--track-plan-file] [--push-every-round]
```

### cancel-rlcr-loop

Gracefully stop a running loop and record a reason.

```
python3 scripts/loop.py cancel-rlcr-loop [--reason REASON]
```

### monitor

Stream live output from the loop or an AI subprocess.

```
python3 scripts/loop.py monitor rlcr [--once]
python3 scripts/loop.py monitor codex [--once]
python3 scripts/loop.py monitor gemini [--once]
```

## End-to-End Workflow

1. Write your idea into `IDEA.md`.
2. Generate a plan:
   ```
   python3 scripts/loop.py gen-plan --input IDEA.md --output plan.md --title "My Feature"
   ```
3. Review `plan.md` and edit as needed (see `loop-refine-plan` skill).
4. Start the RLCR loop:
   ```
   python3 scripts/loop.py start-rlcr-loop plan.md --codex-effort high --push-every-round
   ```
5. Monitor progress:
   ```
   python3 scripts/loop.py monitor rlcr
   ```
6. If a plan-level change is needed, cancel and refine:
   ```
   python3 scripts/loop.py cancel-rlcr-loop --reason "Scope change"
   # edit plan.md, then restart the loop
   ```

## Configuration

Default values are read from `config/default_config.json`:

| Key | Default | Description |
|---|---|---|
| `codex_model` | `gpt-5.1` | Codex model used for review rounds |
| `codex_effort` | `high` | Codex reasoning effort level |
| `bitlesson_model` | `haiku` | Model used for bitlesson generation |
| `agent_teams` | `false` | Enable multi-agent team mode |
| `alternative_plan_language` | `""` | Override plan language (keep empty for English) |
| `gen_plan_mode` | `discussion` | Plan generation mode |

## Related Skills

- `loop-gen-plan` — detailed gen-plan options and workflow
- `loop-rlcr` — detailed RLCR loop options and monitoring
- `loop-refine-plan` — strategies for refining plans between iterations
- `ask-codex` — one-off Codex queries outside the loop
- `ask-gemini` — one-off Gemini queries outside the loop
