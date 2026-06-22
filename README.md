# humanize-loop

**Version: 0.1.0**

An iterative development plugin for Claude Code implementing the RLCR (Ralph-Loop with Codex Review) workflow. Humanize leverages continuous feedback loops where AI-generated code is refined through independent review.

## Core Concepts

- **Iteration over Perfection** -- Instead of expecting perfect output in one shot, Humanize leverages continuous feedback loops where issues are caught early and refined incrementally.
- **One Build + One Review** -- Claude implements, Codex independently reviews. No blind spots.
- **Ralph Loop** -- Iterative refinement continues until all acceptance criteria are met.
- **Begin with the End in Mind** -- Before the loop starts, Humanize ensures the plan is fully understood before execution begins.

## How It Works

The loop has two phases: **Implementation** (Claude works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.

## Install

```bash
# Add the marketplace source
/plugin marketplace add FrankDan77/humanize-loop

# Install the plugin
/plugin install humanize-loop@FrankDan77
```

Requires Claude Code CLI and [Codex CLI](https://github.com/openai/codex) for review functionality.

## Quick Start

1. Generate an idea draft:
   ```bash
   humanize gen-idea "your idea description"
   ```

2. Generate a plan from your draft:
   ```bash
   humanize gen-plan --input draft.md --output docs/plan.md
   ```

3. Run the loop:
   ```bash
   humanize start-rlcr-loop docs/plan.md
   ```

## Project Structure

```
agents/            Agent definition files
commands/          Command documentation files
config/            Configuration files
docs/              User documentation and guides
hooks/             Plugin hooks (validators, lifecycle)
prompt-template/   Prompt templates for various subsystems
scripts/           CLI scripts and library modules
skills/            SKILL.md definitions
templates/         Additional templates
tests/             Test suite
```

## License

MIT