# Install Loop for Claude Code

## Prerequisites

- [codex](https://github.com/openai/codex) -- OpenAI Codex CLI (for review). Verify with `codex --version`.
- `jq` -- JSON processor. Verify with `jq --version`.
- `git` -- Git version control. Verify with `git --version`.

## Option 1: Local Install (Recommended)

Clone the repo and start Claude Code with the plugin directory:

```bash
git clone https://github.com/FrankDan77/loop.git
claude --plugin-dir /path/to/loop
```

Marketplace distribution is not yet available; use the local install for now.

## Option 2: Try Experimental Features (dev branch)

The `dev` branch contains experimental features that are not yet released to `main`. To try them locally:

```bash
git clone https://github.com/FrankDan77/loop.git
cd loop
git checkout dev
```

Then start Claude Code with the local plugin directory:

```bash
claude --plugin-dir /path/to/loop
```

Note: The `dev` branch may contain unstable or incomplete features. For production use, stick with the stable `main` branch.

## Verify Installation

After installing, you should see Loop commands available:

```
/rloop:start-rlcr-loop
/rloop:gen-plan
/rloop:refine-plan
/rloop:ask-codex
```

## Monitor Setup (Optional)

Add the monitoring helper to your shell for real-time progress tracking:

```bash
# Add to your .bashrc or .zshrc
source /path/to/loop/scripts/loop.sh
```

Then use:

```bash
loop monitor rlcr   # Monitor RLCR loop
```

## Other Install Guides

- [Install for Codex](install-for-codex.md)
- [Install for Kimi](install-for-kimi.md)

## Next Steps

See the [Usage Guide](usage.md) for detailed command reference and configuration options.
