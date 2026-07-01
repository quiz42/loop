# Installing loop for Claude Code

This guide walks through installing the loop plugin in Claude Code.

## Prerequisites

- Claude Code CLI installed and running
- Codex CLI installed and on your PATH (see [install-codex.md](install-codex.md))
- An OpenAI API key set as `OPENAI_API_KEY`

## Installation

### Method 1: Marketplace installation (recommended)

#### Step 1: Add the plugin from the marketplace

In a Claude Code session, run:

```
/plugin marketplace add FrankDan77/loop
```

This fetches the plugin metadata from the marketplace.

#### Step 2: Install the plugin

```
/plugin install loop@FrankDan77
```

Claude Code downloads and registers the plugin. You should see a confirmation message listing the available commands.

#### Step 3: Verify the installation

```
/monitor
```

If the plugin is installed correctly, you will see a status message. If Claude Code reports an unknown command, restart your session and try again.

### Method 2: Local installation from GitHub

#### One-click install

Clone the repository and run the installer:

```bash
git clone https://github.com/FrankDan77/loop.git
cd loop
bash scripts/install-local.sh
```

The script automatically:
- Detects your Claude Code plugin directory
- Creates a symlink to the cloned repository
- Makes all scripts executable
- Installs to Codex simultaneously (if Codex is installed)

Restart Claude Code after installation, then verify with `/monitor`.

#### Manual installation

If the automated script doesn't work for your setup:

1. Clone the repository:
   ```bash
   git clone https://github.com/FrankDan77/loop.git ~/loop
   ```

2. Find your Claude Code plugin directory:
   - Linux/WSL: `~/.claude-code/plugins/` or `~/.config/claude-code/plugins/`
   - macOS: `~/Library/Application Support/claude-code/plugins/`
   - Windows: `%APPDATA%\claude-code\plugins\`

3. Create a symlink:
   ```bash
   # Linux/macOS
   ln -s ~/loop ~/.claude-code/plugins/loop
   
   # Windows (requires admin privileges)
   mklink /D "%APPDATA%\claude-code\plugins\loop" "%USERPROFILE%\loop"
   ```

4. Make scripts executable (Linux/macOS):
   ```bash
   chmod +x ~/loop/scripts/*.sh ~/loop/scripts/*.py
   ```

5. Restart Claude Code and verify with `/monitor`.

#### GitHub install (no clone required)

Install directly from GitHub without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/FrankDan77/loop/main/scripts/install-local.sh | bash
```

This downloads and runs the installer. Review the script before running if you have security concerns.

#### Uninstalling local installations

```bash
cd loop
bash scripts/uninstall-local.sh
```

Or manually remove the symlink:
```bash
rm ~/.claude-code/plugins/loop
```

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

This creates `.loop/bitlesson/lessons.md` and `.loop/bitlesson/state.json` in your project root.

## Updating the plugin

To update to the latest version, re-run the install command:

```
/plugin install loop@FrankDan77
```

## Uninstalling

```
/plugin remove loop
```

This removes the plugin and its registered commands. Project files under `.loop/` and `config/` are not deleted.

## Troubleshooting

**Commands not found after install:** Close and reopen your Claude Code session.

**Codex errors during the loop:** Verify that `OPENAI_API_KEY` is set in your environment and that `codex` is on your PATH (`which codex`).

**Permission denied on scripts:** Make the scripts executable:

```bash
chmod +x scripts/bitlesson-init.sh scripts/bitlesson-select.sh scripts/bitlesson-validate-delta.sh
```
