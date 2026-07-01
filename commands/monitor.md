# Command: /loop:monitor

Display live status information for running loop processes. Supports monitoring the RLCR loop, Codex reviewer activity, and Gemini-based tasks.

## Usage

```
/loop:monitor TARGET [options]
```

Internally runs:

```
loop monitor rlcr|codex|gemini [--once]
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `TARGET` | Yes | What to monitor. One of: `rlcr`, `codex`, `gemini` |

### Targets

| Target | Description |
|--------|-------------|
| `rlcr` | Monitor the active RLCR loop: current round, goal completion, drift status, and reviewer signal |
| `codex` | Monitor Codex reviewer activity: current review in progress, model/effort settings, and recent review results |
| `gemini` | Monitor Gemini-based agent activity and task status |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--once` | off | Print the current status snapshot and exit immediately, instead of watching continuously |

## What It Does

Without `--once`, the command enters a live watch mode, refreshing the status display at a regular interval until the user exits (Ctrl+C) or the monitored process terminates.

With `--once`, it prints a single snapshot and returns — useful for scripting or quick status checks.

The `rlcr` target pulls data from the `goal-tracker` (goal completion), the `drift-monitor` (drift severity and history), and the loop orchestrator (current round, reviewer signal).

## Example Usage

```
# Watch the RLCR loop live
/loop:monitor rlcr

# Single snapshot of the RLCR loop (useful in scripts)
/loop:monitor rlcr --once

# Watch Codex reviewer activity
/loop:monitor codex

# Single Gemini status snapshot
/loop:monitor gemini --once
```

## Expected Output

### `rlcr` target

```
[loop:monitor] RLCR Loop — Round 3 / max 42
Goals:      ████████░░░░░░░░  4 / 7 complete
Drift:      minor (round 2: 1 deviation)
Last review: NEEDS_REVISION (2 blocking issues)
Agents:     implementer=running  code-reviewer=idle  goal-tracker=active  drift-monitor=active
```

### `rlcr --once` target

```
[loop:monitor] RLCR Loop snapshot @ 2026-06-25T13:37:41Z
Round: 3 / 42 | Goals: 4/7 | Drift: minor | Last review: NEEDS_REVISION
```

### `codex` target

```
[loop:monitor] Codex Reviewer
Model:  gpt-5.5  |  Effort: high
Status: reviewing round 3 diff...
Last result: NEEDS_REVISION — 2 blocking, 1 non-blocking
```
