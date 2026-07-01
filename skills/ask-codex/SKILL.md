---
name: ask-codex
description: Ask a question to OpenAI Codex and get a direct answer
---

# Ask Codex

Send a question or prompt to OpenAI Codex via the loop toolchain. Useful for code generation, review, debugging, and technical Q&A during the RLCR workflow.

## Usage

```
python3 scripts/ask_tool.py codex [OPTIONS] QUESTION
```

## Options

| Option | Description |
|---|---|
| `--codex-model MODEL` | Codex model to use (default: gpt-5.5 from config) |
| `--codex-effort high` | Set reasoning effort level to high for complex tasks |
| `--bypass-sandbox` | Run without sandbox restrictions (use with caution) |

## Examples

Ask a straightforward code question:
```
python3 scripts/ask_tool.py codex "How should I implement retry logic in Python?"
```

Ask with high effort for complex reasoning:
```
python3 scripts/ask_tool.py codex --codex-effort high "Review this algorithm and identify edge cases"
```

Specify a model explicitly:
```
python3 scripts/ask_tool.py codex --codex-model gpt-5.5 --codex-effort high "Refactor this function for readability"
```

Bypass sandbox for filesystem-aware queries:
```
python3 scripts/ask_tool.py codex --bypass-sandbox "What files in this repo need updating?"
```

## Notes

- Default model and effort are read from `config/default_config.json` (`codex_model`, `codex_effort`).
- `--bypass-sandbox` allows Codex to access the local environment; only use when necessary.
- During the RLCR loop, Codex is invoked automatically for code review rounds. Use this skill for one-off queries outside the loop.
