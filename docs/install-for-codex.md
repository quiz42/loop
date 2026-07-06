# Installing Codex CLI for loop

loop uses the Codex CLI as the code review engine inside the RLCR loop. This guide covers installing and configuring Codex CLI.

## What is Codex CLI

Codex CLI is an open-source command-line tool by OpenAI that runs AI-powered code tasks in your terminal. Repository: https://github.com/openai/codex

## Installing loop for Codex

### Method 1: One-click install (local/GitHub)

The same `install-local.sh` script installs loop for both Claude Code and Codex simultaneously:

```bash
# From cloned repository
git clone https://github.com/FrankDan77/loop.git
cd loop
bash scripts/install-local.sh
```

Or directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/FrankDan77/loop/main/scripts/install-local.sh | bash
```

The installer detects your Codex plugin directory (`~/.codex/plugins/` or `~/.config/codex/plugins/`) and creates a symlink automatically.

### Method 2: Manual Codex installation

1. Clone the repository:
   ```bash
   git clone https://github.com/FrankDan77/loop.git ~/loop
   ```

2. Find or create your Codex plugin directory:
   ```bash
   mkdir -p ~/.codex/plugins
   ```

3. Create a symlink:
   ```bash
   ln -s ~/loop ~/.codex/plugins/loop
   ```

4. Make scripts executable:
   ```bash
   chmod +x ~/loop/scripts/*.sh ~/loop/scripts/*.py
   ```

### Uninstalling from Codex

```bash
cd loop && bash scripts/uninstall-local.sh
# or manually:
rm ~/.codex/plugins/loop
```

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

## Configuration in loop

loop controls Codex behavior through `config/default_config.json`:

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
