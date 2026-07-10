# Command: /loop:ask-gemini

Send a one-shot research or design question to Gemini through the loop toolchain. Use this for broad comparisons, research-backed plan critique, and cross-model validation outside the main RLCR cycle.

## Usage

```
/loop:ask-gemini [options] QUESTION
```

Internally runs:

```
loop ask-gemini [--gemini-model MODEL] [--gemini-timeout SECONDS] [--yolo] QUESTION
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--gemini-model MODEL` | `gemini-3.1-pro-preview` | Gemini model to use for the one-shot question |
| `--gemini-timeout SECONDS` | `3600` | Maximum runtime before the request is treated as failed |
| `--yolo` | off | Run Gemini without the default sandbox confirmation flow |

## What It Does

1. Writes the question to the loop skill runtime under `.loop/skill/`.
2. Executes a one-shot Gemini request with the selected model.
3. Stores command, logs, and output metadata for later monitoring.
4. Prints the Gemini answer to stdout when the request succeeds.

## Example Usage

```
# Ask a design question
/loop:ask-gemini "What tradeoffs should we consider before splitting this service into workers?"

# Use a specific Gemini model
/loop:ask-gemini --gemini-model gemini-3.1-pro-preview "Compare these plan alternatives"

# Skip confirmation prompts for scripted use
/loop:ask-gemini --yolo "Review this plan and list the biggest missing edge cases"
```

