# Command: /loop:cancel-rlcr-loop

Cancel a running RLCR loop. The current implementation round is allowed to finish cleanly before the loop is stopped, ensuring no partial changes are left in an inconsistent state.

## Usage

```
/loop:cancel-rlcr-loop [options]
```

Internally runs:

```
loop cancel-rlcr-loop [--reason REASON]
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--reason REASON` | *(none)* | Human-readable explanation for why the loop is being cancelled. Recorded in the loop log and shown in the final status output. |

## What It Does

1. Sends a cancellation signal to the running RLCR loop orchestrator.
2. Waits for the current implementation or review step to complete (no mid-step interruption).
3. Records the cancellation reason (if provided) in the loop log.
4. Prints a final status summary showing how many rounds completed and which goals were met before cancellation.

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
[loop] Cancellation requested. Waiting for current round to finish...
[loop] Round 3 complete. Stopping loop.
[loop] Loop cancelled after 3 rounds.
[loop] Goals completed: 4 / 7
[loop] Reason: Changing approach — plan needs to be revised
```

If no loop is active:

```
[loop] No active RLCR loop found. Nothing to cancel.
```
