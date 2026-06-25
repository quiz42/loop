# Installing Codex CLI for humanize-loop

humanize-loop uses the Codex CLI as the code review engine inside the RLCR loop. This guide covers installing and configuring Codex CLI.

## What is Codex CLI

Codex CLI is an open-source command-line tool by OpenAI that runs AI-powered code tasks in your terminal. Repository: https://github.com/openai/codex

## Prerequisites

- Node.js 18 or later
- An OpenAI API key

## Installation

### Option A: Install via npm (recommended)

```bash
npm install -g @openai/codex
```

Verify the installation:

```bash
codex --version
```

### Option B: Install from source

```bash
git clone https://github.com/openai/codex.git
cd codex
npm install
npm run build
npm link
```

## Configuration

### Set your API key

Codex CLI reads the `OPENAI_API_KEY` environment variable. Add it to your shell profile:

```bash
export OPENAI_API_KEY="sk-..."
```

Or set it for a single session:

```bash
OPENAI_API_KEY="sk-..." /start-rlcr-loop
```

### Confirm Codex can reach the API

```bash
codex "print hello world in Python"
```

You should see a brief code snippet returned. If you see an authentication error, double-check your API key.

## Configuration in humanize-loop

humanize-loop controls Codex behavior through `config/default_config.json`:

```json
{
  "codex_model": "gpt-5.5",
  "codex_effort": "high"
}
```

- `codex_model`: The OpenAI model Codex CLI will use for review. Must be a model your API key has access to.
- `codex_effort`: Reasoning effort passed to Codex. Higher effort produces more thorough reviews at greater cost. Accepted values: `low`, `medium`, `high`.

## Troubleshooting

**`codex: command not found`:** Ensure the npm global bin directory is on your PATH. Run `npm bin -g` to find it, then add it to `~/.bashrc` or `~/.zshrc`.

**Rate limit errors:** Lower `codex_effort` to `medium` or `low`, or reduce loop iteration frequency.

**Model not available:** Update `codex_model` in `config/default_config.json` to a model available on your account.
