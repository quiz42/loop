# loop

**Version: 0.1.0**

An iterative development plugin for Claude Code and Codex implementing the RLCR (Ralph-Loop with Codex Review) workflow. Loop leverages continuous feedback loops where AI-generated code is refined through independent review.

## Core Concepts

- **Iteration over Perfection** — Instead of expecting perfect output in one shot, loop leverages continuous feedback loops where issues are caught early and refined incrementally.
- **One Build + One Review** — Claude implements, Codex independently reviews. No blind spots.
- **Ralph Loop** — Iterative refinement continues until all acceptance criteria are met.
- **Begin with the End in Mind** — Before the loop starts, loop ensures the plan is fully understood before execution begins.

## How It Works

The loop has two phases: **Implementation** (Claude works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.

![RLCR workflow](docs/images/rlcr-workflow.svg)

## Prerequisites

- **Python 3.10+** — Required for running loop scripts
- **[uv](https://docs.astral.sh/uv/)** — Fast Python package manager (installed automatically if missing)
- **Claude Code CLI** — Required for Claude-based implementation
- **[Codex CLI](https://github.com/openai/codex)** — Required for independent code review
- **OpenAI API key** — Set as `OPENAI_API_KEY` environment variable

### Installing uv (if not already installed)

uv is a fast Python package and project manager. The install script will auto-install it, or you can install manually:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

After installation, uv is available at `~/.cargo/bin/uv`. You may need to restart your shell or add it to PATH:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
```

Verify installation:

```bash
uv --version
```

For detailed uv documentation, see: https://docs.astral.sh/uv/

## Installation

### Method 1: Marketplace installation (Claude Code only)

```bash
# Add the marketplace source
/plugin marketplace add FrankDan77/loop

# Install the plugin
/plugin install loop@FrankDan77
```

### Method 2: Local/GitHub installation (Claude Code + Codex)

**One-click install from GitHub:**

```bash
curl -fsSL https://raw.githubusercontent.com/FrankDan77/loop/main/scripts/install-local.sh | bash
```

**Or clone and install:**

```bash
git clone https://github.com/FrankDan77/loop.git
cd loop
bash scripts/install-local.sh
```

The installer automatically detects and installs the plugin for both Claude Code and Codex (if installed).

**What the installer does:**
- Installs uv (if not already present)
- Runs `uv sync` to create a `.venv/` with all Python dependencies in the cloned repo
- **Copies** loop scripts to `~/.local/lib/loop/` (persistent installation)
- Creates `~/.local/bin/loop` wrapper script for global access
- Symlinks the plugin to Claude Code and Codex plugin directories

After installation, you can:
- Run `loop` directly from any directory (if `~/.local/bin` is in PATH)
- Delete the cloned repo if desired — the `loop` command will continue to work
- Or use inside Claude Code with `/` prefix (e.g., `/monitor`)

**Important:** The loop CLI is **copied** to `~/.local/lib/loop/`, not symlinked. This means:
- ✅ You can safely delete the cloned repository after installation
- ✅ The `loop` command will continue to work
- ⚠️  Updates require re-running `install-local.sh` to refresh the installed files

**Uninstall:**

```bash
bash scripts/uninstall-local.sh
```

### Prerequisites

- **Claude Code CLI** — Required for Claude-based implementation
- **[Codex CLI](https://github.com/openai/codex)** — Required for independent code review
- **OpenAI API key** — Set as `OPENAI_API_KEY` environment variable

For detailed installation instructions, see:
- [Installing loop for Claude Code](docs/install-for-claude.md)
- [Installing loop for Codex](docs/install-for-codex.md)
- [Installing loop for Kimi](docs/install-for-kimi.md)

## Quick Start

### 1. Verify installation

After installation, restart Claude Code and run:

```bash
/monitor
```

You should see the loop status dashboard.

```text
Loop RLCR Monitor
Status:  idle
Round:   0 / 0
Git:     clean
```

### 2. Initialize configuration (optional)

```bash
# Create default config if not present
/monitor
```

Edit `config/default_config.json` to customize model settings, effort levels, and hooks.

### 3. Generate an idea draft

```bash
loop gen-idea "Build a CLI tool for managing TODO lists with SQLite backend"
```

This creates an idea draft under `.loop/ideas/` with project overview, directed exploration slots, goals, and constraints.

### 4. Create a plan

```bash
loop gen-plan --input .loop/ideas/idea-build-a-cli-tool-for-managing-todo-lists-with-sqlite-backend.md --output docs/plan.md
```

This generates a detailed implementation plan with path boundaries, task routing, pending decisions, and acceptance criteria.

### 5. Start the RLCR loop

```bash
loop start-rlcr-loop docs/plan.md
```

The loop runs until all tasks are complete and all acceptance criteria are met.

## Commands

| Command | Description |
|---------|-------------|
| `loop gen-idea <description>` | Generate an idea draft from a description |
| `loop gen-plan --input <draft> --output <plan>` | Convert idea draft to detailed plan |
| `loop refine-plan --input <plan>` | Refine an annotated plan and write a QA ledger |
| `loop ask-codex <question>` | Send a one-shot question to Codex |
| `loop ask-gemini <question>` | Send a one-shot question to Gemini |
| `loop bitlesson <subcommand>` | Manage Bitter Lesson workflow files |
| `loop install <subcommand>` | Install loop hooks and skills |
| `loop validate <subcommand>` | Validate planning command inputs and outputs |
| `loop start-rlcr-loop <plan>` | Start the RLCR implementation loop |
| `loop monitor` | Show loop status dashboard |
| `loop cancel-rlcr-loop` | Stop a running loop |

For Claude Code, prefix with `/` (e.g., `/monitor`).

For full command documentation, see [`commands/`](commands/) directory.

## Configuration

Loop behavior is controlled via `config/default_config.json`:

```json
{
  "codex_model": "gpt-5.5",
  "codex_effort": "high",
  "claude_model": "claude-sonnet-4",
  "max_iterations": 10,
  "hooks": {
    "pre_commit": "hooks/validators.py",
    "post_review": "hooks/lib/loop_common.py"
  }
}
```

**Key settings:**
- `codex_model` — Model used by Codex for code review
- `codex_effort` — Review effort: `low`, `medium`, `high`
- `max_iterations` — Maximum loop iterations before timeout
- `hooks` — Custom validation and lifecycle hooks

See [Configuration Guide](docs/usage.md#configuration) for details.

Runtime state is written under `.loop/` and should stay untracked. Project-specific overrides can be placed in `.loop/config.json`, or you can point `LOOP_CONFIG` at another JSON file. The optional status line reads `LOOP_MODEL` and `LOOP_STATUS` from the environment when present.

## Dependency Management with uv

This project uses [uv](https://docs.astral.sh/uv/) for fast, reliable Python dependency management.

### Common uv commands

```bash
# Install/sync all dependencies (creates .venv/)
uv sync

# Include dev dependencies (pytest, etc.)
uv sync --extra dev

# Add a new runtime dependency
uv add <package>

# Add a dev-only dependency
uv add --dev <package>

# Run a script inside the managed environment
uv run scripts/loop.py monitor

# Activate the virtual environment manually
source .venv/bin/activate
```

### Why uv?

- **10-100x faster** than pip for installing packages
- **Deterministic** — lockfile ensures reproducible installs
- **Built-in virtual environment** management
- **Drop-in replacement** for pip, poetry, and pipenv

All dependencies are declared in `pyproject.toml`. Currently, loop uses only Python standard library modules, but uv is ready when external packages are needed.

## Skills

Loop includes pre-built skills for common workflows:

- **[loop](skills/loop/SKILL.md)** — Core RLCR workflow
- **[loop-gen-plan](skills/loop-gen-plan/SKILL.md)** — Plan generation
- **[loop-refine-plan](skills/loop-refine-plan/SKILL.md)** — Plan refinement
- **[loop-rlcr](skills/loop-rlcr/SKILL.md)** — RLCR loop orchestration

Skills are Markdown documents that agents use as context for specific tasks.

## Agents

Loop uses specialized agents for different phases:

- **[goal-tracker.md](agents/goal-tracker.md)** — Tracks progress against acceptance criteria
- **[drift-monitor.md](agents/drift-monitor.md)** — Detects scope creep and plan deviation
- **[code-reviewer.md](agents/code-reviewer.md)** — Performs independent code review via Codex

## Documentation

- **[Usage Guide](docs/usage.md)** — Complete usage documentation
- **[Installing for Claude Code](docs/install-for-claude.md)** — Detailed Claude Code setup
- **[Installing for Codex](docs/install-for-codex.md)** — Detailed Codex setup
- **[Installing for Kimi](docs/install-for-kimi.md)** — Detailed Kimi setup
- **[Bitter Lesson Workflow](docs/bitlesson.md)** — Optional research-oriented workflow

## Project Structure

```
loop/
├── agents/              # Agent definition files
├── commands/            # Command documentation
├── config/              # Configuration files
│   └── codex-hooks.json
├── docs/                # User documentation
│   ├── images/
│   ├── install-for-claude.md
│   ├── install-for-codex.md
│   ├── install-for-kimi.md
│   ├── usage.md
│   └── bitlesson.md
├── hooks/               # Plugin hooks (validators, lifecycle)
│   ├── lib/
│   └── validators.py
├── prompt-template/     # Prompt templates for subsystems
│   ├── block/
│   ├── claude/
│   ├── codex/
│   ├── idea/
│   └── plan/
├── scripts/             # CLI scripts and library modules
│   ├── loop.sh          # Main CLI entry point
│   ├── loop.py          # Python implementation
│   ├── install-local.sh # Local installer
│   └── lib/             # Shared libraries
├── skills/              # SKILL.md definitions
│   ├── loop/
│   ├── loop-gen-plan/
│   ├── loop-refine-plan/
│   └── loop-rlcr/
└── tests/               # Test suite
```

## Testing

Run the test suite:

```bash
# Run all tests
bash tests/run-all-tests.sh

# Or use unittest directly
python3 -m unittest discover -s tests
```

Tests cover:
- CLI command parsing
- Configuration loading
- Hook validation
- Monitor dashboard
- RLCR loop orchestration
- Shell template loading and rendering regressions
- Shell guards that prevent `.loop/` runtime state from being staged
- Shell command pattern detection for protected runtime files

GitHub Actions workflows under `.github/workflows/` run the same core checks in CI, including the full unittest suite, shell syntax validation, template coverage, plan-file validation, and release version bump checks.

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Links

- **Repository:** https://github.com/FrankDan77/loop
- **Codex CLI:** https://github.com/openai/codex
- **Claude Code:** https://claude.ai/code
