# Command: /loop:bitlesson

Manage the Bitter Lesson workflow files used to capture reusable implementation lessons between RLCR iterations.

## Usage

```
/loop:bitlesson <subcommand> [options]
```

Internally runs:

```
loop bitlesson init [--force]
loop bitlesson select [QUERY]
loop bitlesson validate-delta DELTA.md
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `init` | Create `.loop/bitlesson/lessons.md` and `.loop/bitlesson/state.json` if they do not exist |
| `select` | Print the most relevant lesson entry, optionally filtered by a query |
| `validate-delta` | Validate that a proposed lesson delta contains the required sections |

## Example Usage

```
# Initialize the workflow
/loop:bitlesson init

# Rebuild the workflow files from scratch
/loop:bitlesson init --force

# Retrieve the latest or matching lesson
/loop:bitlesson select "dependency injection"

# Validate a proposed lesson delta
/loop:bitlesson validate-delta docs/bitlesson-delta.md
```

