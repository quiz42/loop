# Command: /loop:install

Install loop hook and skill assets into local tool directories. This command exposes the same installation helpers as the legacy shell wrappers, but through the main `loop` CLI.

## Usage

```
/loop:install <subcommand> [options]
```

Internally runs:

```
loop install codex-hooks [--plugin-root DIR] [--target-dir DIR]
loop install skill SOURCE [--destination DIR]
loop install skills-codex [--plugin-root DIR] [--destination DIR]
loop install skills-kimi [--plugin-root DIR] [--destination DIR]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `codex-hooks` | Copy loop Codex hooks and `codex-hooks.json` into the target Codex directory |
| `skill` | Install one skill directory or file into a skill destination |
| `skills-codex` | Install bundled loop skills for the Codex profile |
| `skills-kimi` | Install bundled loop skills for the Kimi profile |

## Example Usage

```
# Install Codex hooks from the current plugin checkout
/loop:install codex-hooks --plugin-root . --target-dir ~/.codex/loop

# Install one skill into a custom destination
/loop:install skill skills/loop --destination ~/.loop/skills

# Install bundled skills for Codex or Kimi
/loop:install skills-codex --plugin-root . --destination ~/.loop/skills
/loop:install skills-kimi --plugin-root . --destination ~/.loop/skills
```

