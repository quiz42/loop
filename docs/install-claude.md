# Installing loop for Claude Code

This guide walks through installing the loop plugin in Claude Code.

## Prerequisites

- Claude Code CLI installed and running
- Codex CLI installed and on your PATH (see [install-codex.md](install-codex.md))
- An OpenAI API key set as `OPENAI_API_KEY`

## Installation

### Step 1: Add the plugin from the marketplace

In a Claude Code session, run:

```
/plugin marketplace add FrankDan77/loop
```

This fetches the plugin metadata from the marketplace.

### Step 2: Install the plugin

```
/plugin install loop@FrankDan77
```

Claude Code downloads and registers the plugin. You should see a confirmation message listing the available commands.

### Step 3: Verify the installation

```
/monitor
```

If the plugin is installed correctly, you will see a status message. If Claude Code reports an unknown command, restart your session and try again.

## Post-installation setup

### Initialize configuration

The plugin ships with a default configuration at `config/default_config.json`. Review it and adjust values for your project before running your first loop:

```json
{
  "codex_model": "gpt-5.5",
  "codex_effort": "high",
  "bitlesson_model": "haiku",
  "agent_teams": false
}
```

### Initialize the Bitter Lesson workflow (optional)

```bash
bash scripts/bitlesson-init.sh
```

This creates `.humanize/bitlesson/lessons.md` and `.humanize/bitlesson/state.json` in your project root.

## Updating the plugin

To update to the latest version, re-run the install command:

```
/plugin install loop@FrankDan77
```

## Uninstalling

```
/plugin remove loop
```

This removes the plugin and its registered commands. Project files under `.humanize/` and `config/` are not deleted.

## Troubleshooting

**Commands not found after install:** Close and reopen your Claude Code session.

**Codex errors during the loop:** Verify that `OPENAI_API_KEY` is set in your environment and that `codex` is on your PATH (`which codex`).

**Permission denied on scripts:** Make the scripts executable:

```bash
chmod +x scripts/bitlesson-init.sh scripts/bitlesson-select.sh scripts/bitlesson-validate-delta.sh
```
