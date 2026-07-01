# loop Usage Guide

loop is a Claude Code plugin that implements the RLCR (Ralph-Loop with Codex Review) iterative development workflow. It orchestrates idea generation, planning, and iterative code review cycles using Claude Code and the Codex CLI.

## Prerequisites

- Claude Code CLI installed and authenticated
- Codex CLI installed (see [install-codex.md](install-codex.md))
- Plugin installed (see [install-claude.md](install-claude.md))

## Quick Start

The standard workflow proceeds in four steps:

### 1. Generate an idea

```
/gen-idea
```

Prompts you to describe a feature or problem. Claude Code generates a structured idea document in `.loop/ideas/`.

### 2. Generate a plan

```
/gen-plan
```

Takes the current idea and produces a step-by-step implementation plan. The plan is saved to `.loop/plans/`.

### 3. Start the RLCR loop

```
/start-rlcr-loop
```

Begins the iterative loop. On each iteration:
1. Claude Code implements the next plan step.
2. Codex CLI reviews the diff.
3. Review feedback is incorporated before proceeding.

The loop runs until the plan is complete or you cancel it.

### 4. Monitor progress

```
/monitor
```

Displays the current loop state, iteration count, active plan step, and any pending review comments.

### Cancel the loop

```
/cancel-rlcr-loop
```

Stops the loop after the current iteration finishes cleanly.

## Configuration

Configuration lives in `config/default_config.json`:

```json
{
  "codex_model": "gpt-5.5",
  "codex_effort": "high",
  "bitlesson_model": "haiku",
  "agent_teams": false
}
```

| Key | Description | Default |
|-----|-------------|---------|
| `codex_model` | Codex model used for code review | `gpt-5.5` |
| `codex_effort` | Codex reasoning effort level (`low`, `medium`, `high`) | `high` |
| `bitlesson_model` | Model used to summarize Bitter Lesson entries | `haiku` |
| `agent_teams` | Enable experimental multi-agent team mode | `false` |

Edit this file before starting a loop to change behavior for the entire session.

## Common Workflows

### Start fresh from an idea

```
/gen-idea
/gen-plan
/start-rlcr-loop
/monitor
```

### Resume after cancellation

If a loop was cancelled mid-way, the plan state is preserved. Run `/start-rlcr-loop` again to resume from the last completed step.

### Run tests after each iteration

The loop automatically runs `python3 -m unittest discover -s tests` after each implementation step. Failures are surfaced as review feedback before Codex review begins.

### Track lessons learned

See [bitlesson.md](bitlesson.md) for how to capture and use Bitter Lesson entries alongside the RLCR loop.
