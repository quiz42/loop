# Command: /loop:cancel-rlcr-loop

Cancel a running RLCR loop. The current implementation round is allowed to finish cleanly before the loop is stopped, ensuring no partial changes are left in an inconsistent state.

## Usage

```
/loop:cancel-rlcr-loop [options]
```

Internally runs:

```
loop cancel-rlcr-loop [--reason REASON] [--force]
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--reason REASON` | `Cancelled by user request.` | Human-readable explanation shown in the final status output |
| `--force` | off | Cancel even when the loop is in finalize phase |

## What It Does

1. Finds the active loop session under `.loop/rlcr`.
2. Writes a `.cancel-requested` signal file.
3. Removes `.loop/.pending-session-id`.
4. Moves the active state file to `cancel-state.md`.
5. Prints a final status summary and the cancellation reason.

If no loop is currently running, the command exits immediately with an informational message.

## Example Usage

```
# Cancel with no reason
/loop:cancel-rlcr-loop

# Cancel with an explanation
/loop:cancel-rlcr-loop --reason "Changing approach — plan needs to be revised"
```

## Expected Output

```
CANCELLED
Cancelled RLCR loop (was at round 3 of 9).
State preserved as cancel-state.md
Reason: Changing approach - plan needs to be revised
```

If no loop is active:

```
No active RLCR loop found.
```
