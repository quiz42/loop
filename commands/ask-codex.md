# Command: /loop:ask-codex

Send a one-shot question to Codex through the loop toolchain. Use this for focused implementation questions, code review follow-ups, and repo-aware technical checks outside the main RLCR cycle.

## Usage

```
/loop:ask-codex [options] QUESTION
```

Internally runs:

```
loop ask-codex [--codex-model MODEL] [--codex-effort LEVEL] [--codex-timeout SECONDS] [--bypass-sandbox] QUESTION
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--codex-model MODEL` | `gpt-5.5` | Codex model to use for the one-shot question |
| `--codex-effort LEVEL` | `high` | Reasoning effort to pass to Codex |
| `--codex-timeout SECONDS` | `3600` | Maximum runtime before the request is treated as failed |
| `--bypass-sandbox` | off | Use Codex's unsandboxed execution mode for environment-aware queries |

## What It Does

1. Writes the question to the loop skill runtime under `.loop/skill/`.
2. Executes a one-shot Codex request with the selected model and effort.
3. Stores command, logs, and output metadata for later monitoring.
4. Prints the Codex answer to stdout when the request succeeds.

## Example Usage

```
# Ask a direct implementation question
/loop:ask-codex "How should this retry helper handle exponential backoff?"

# Use a specific model and effort
/loop:ask-codex --codex-model gpt-5.5 --codex-effort high "Review this migration plan for risks"

# Allow environment-aware inspection when necessary
/loop:ask-codex --bypass-sandbox "Which files in this repo are most likely affected by the new config option?"
```

