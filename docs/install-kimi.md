# Using Kimi as an Alternative Review Model

humanize-loop uses Codex CLI for code review by default. If you prefer Kimi (Moonshot AI) as your review model, this guide explains how to configure it.

## What is Kimi

Kimi is a large language model by Moonshot AI with strong code understanding capabilities. It can serve as a drop-in alternative to Codex for the review step in the RLCR loop.

## Prerequisites

- A Moonshot AI API key (https://platform.moonshot.cn)
- Kimi API access enabled on your account

## Configuration

Kimi support in humanize-loop is configured through `config/default_config.json`. Set `bitlesson_model` to `kimi` and point the review model to the Kimi endpoint:

```json
{
  "codex_model": "moonshot-v1-8k",
  "codex_effort": "high",
  "bitlesson_model": "kimi",
  "agent_teams": false
}
```

Set your Moonshot API key in the environment:

```bash
export MOONSHOT_API_KEY="sk-..."
```

humanize-loop reads `MOONSHOT_API_KEY` when `bitlesson_model` is set to `kimi` and routes review requests to the Moonshot API.

## Available Kimi models

| Model | Context window | Notes |
|-------|---------------|-------|
| `moonshot-v1-8k` | 8 000 tokens | Fast, suitable for most diffs |
| `moonshot-v1-32k` | 32 000 tokens | Use for large changeset reviews |
| `moonshot-v1-128k` | 128 000 tokens | Full-repo context |

Set the model name as `codex_model` in the config file.

## Installing the Moonshot Python SDK (optional)

If you are using bitlesson.py with Kimi directly:

```bash
pip install moonshot
```

Then in your Python code:

```python
import os
from moonshot import Moonshot

client = Moonshot(api_key=os.environ["MOONSHOT_API_KEY"])
```

## Switching back to Codex

To revert to the default Codex reviewer, restore the original config values:

```json
{
  "codex_model": "gpt-5.5",
  "codex_effort": "high",
  "bitlesson_model": "haiku",
  "agent_teams": false
}
```

And ensure `OPENAI_API_KEY` is set in your environment.

## Troubleshooting

**Authentication errors:** Confirm `MOONSHOT_API_KEY` is exported and matches the key shown in your Moonshot dashboard.

**Model not found:** Check that the model name matches exactly. Kimi model names are case-sensitive.

**Slow responses:** Switch to `moonshot-v1-8k` for faster turnaround on small diffs.
