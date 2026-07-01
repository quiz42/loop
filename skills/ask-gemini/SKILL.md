---
name: ask-gemini
description: Ask a question to Google Gemini and get a direct answer
---

# Ask Gemini

Send a question or prompt to Google Gemini via the loop toolchain. Useful for large-context analysis, design review, and cross-model validation during the RLCR workflow.

## Usage

```
python3 scripts/ask_tool.py gemini [OPTIONS] QUESTION
```

## Options

| Option | Description |
|---|---|
| `--gemini-model MODEL` | Gemini model to use (default: gemini-3.1-pro-preview) |
| `--yolo` | Skip confirmation prompts and run immediately |

## Examples

Ask a design question:
```
python3 scripts/ask_tool.py gemini "What are the tradeoffs between event sourcing and CQRS?"
```

Use a specific model:
```
python3 scripts/ask_tool.py gemini --gemini-model gemini-3.1-pro-preview "Summarize the architecture of this codebase"
```

Skip confirmation prompts for scripted use:
```
python3 scripts/ask_tool.py gemini --yolo "Review the plan and suggest improvements"
```

## Notes

- Default model is `gemini-3.1-pro-preview`. Override with `--gemini-model` as needed.
- `--yolo` suppresses interactive confirmations, suitable for automation and loop scripts.
- Gemini is well-suited for long-context tasks such as reviewing entire plan files or large diffs.
- During the RLCR loop, Gemini may be used for plan critique rounds. Use this skill for one-off queries outside the loop.
