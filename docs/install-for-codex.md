# Install Loop Skills for Codex

This guide explains how to install Loop for Codex CLI, including the skill runtime (`$CODEX_HOME/skills`) and the native Codex `Stop` hook (`$CODEX_HOME/hooks.json`).

## Quick Install (Recommended)

One-line install from anywhere:

```bash
tmp_dir="$(mktemp -d)" && git clone --depth 1 https://github.com/FrankDan77/loop.git "$tmp_dir/loop" && "$tmp_dir/loop/scripts/install-skills-codex.sh"
```

From the Loop repo root:

```bash
./scripts/install-skills-codex.sh
```

Or use the unified installer directly:

```bash
./scripts/install-skill.sh --target codex
```

This will:
- Sync `loop`, `loop-gen-plan`, `loop-refine-plan`, and `loop-rlcr` into `${CODEX_HOME:-~/.codex}/skills`
- Copy runtime dependencies into `${CODEX_HOME:-~/.codex}/skills/loop`
- Install/update native Loop Stop hooks in `${CODEX_HOME:-~/.codex}/hooks.json`
- Enable the experimental `codex_hooks` feature in `${CODEX_HOME:-~/.codex}/config.toml` when `codex` is available
- Seed `~/.config/loop/config.json` with a Codex/OpenAI `bitlesson_model` when that key is not already set
- Mark the install as `provider_mode: "codex-only"` when using `--target codex`
- Use RLCR defaults: `codex exec` with `gpt-5.5:high`, `codex review` with `gpt-5.5:high`

Requires Codex CLI `0.114.0` or newer for native hooks. Older Codex builds are not supported by the Codex install path.

## Verify

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills"
```

Expected directories:
- `loop`
- `loop-gen-plan`
- `loop-refine-plan`
- `loop-rlcr`

Runtime dependencies in `loop/`:
- `scripts/`
- `hooks/`
- `prompt-template/`
- `templates/`
- `config/`
- `agents/`

Installed files/directories:
- `${CODEX_HOME:-~/.codex}/skills/loop/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/loop-gen-plan/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/loop-refine-plan/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/loop-rlcr/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/loop/scripts/`
- `${CODEX_HOME:-~/.codex}/skills/loop/hooks/`
- `${CODEX_HOME:-~/.codex}/skills/loop/prompt-template/`
- `${CODEX_HOME:-~/.codex}/skills/loop/templates/`
- `${CODEX_HOME:-~/.codex}/skills/loop/config/`
- `${CODEX_HOME:-~/.codex}/skills/loop/agents/`
- `${CODEX_HOME:-~/.codex}/hooks.json`
- `${XDG_CONFIG_HOME:-~/.config}/loop/config.json` (created or updated only when Loop config keys are unset)

Verify native hooks:

```bash
codex features list | rg codex_hooks
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
```

Expected:
- `codex_hooks` is `true`
- `hooks.json` contains `loop-codex-stop-hook.sh`
- `${XDG_CONFIG_HOME:-~/.config}/loop/config.json` contains `bitlesson_model` set to a Codex/OpenAI model such as `gpt-5.5`
- for `--target codex`, `${XDG_CONFIG_HOME:-~/.config}/loop/config.json` also contains `provider_mode: "codex-only"`

## Optional: Install for Both Codex and Kimi

```bash
./scripts/install-skill.sh --target both
```

## Useful Options

```bash
# Preview without writing
./scripts/install-skills-codex.sh --dry-run

# Custom Codex skills dir
./scripts/install-skills-codex.sh --codex-skills-dir /custom/codex/skills

# Reinstall only the native hooks/config
./scripts/install-codex-hooks.sh
```

## Troubleshooting

If scripts are not found from installed skills:

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills/loop/scripts"
```

If native exit gating does not trigger:

```bash
codex features enable codex_hooks
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
```
