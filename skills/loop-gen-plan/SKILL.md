---
name: loop-gen-plan
description: Generate a structured implementation plan from an idea file
---

# Humanize Gen-Plan

Generate a structured, AI-driven implementation plan from a raw idea or requirements document. The output plan is used as the entry point for the RLCR loop.

## Usage

```
python3 scripts/loop.py gen-plan [OPTIONS]
```

## Options

| Option | Description |
|---|---|
| `--input FILE` | Input idea file (default: IDEA.md) |
| `--output FILE` | Output plan file (default: plan.md) |
| `--title TITLE` | Title for the generated plan |

## Examples

Generate a plan from the default IDEA.md:
```
python3 scripts/loop.py gen-plan
```

Specify input and output files:
```
python3 scripts/loop.py gen-plan --input my_idea.md --output my_plan.md
```

Set a custom title:
```
python3 scripts/loop.py gen-plan --input IDEA.md --output plan.md --title "Refactor Auth Module"
```

## Workflow

1. Write your idea or requirements into an input file (e.g., `IDEA.md`).
2. Run `gen-plan` to produce a structured `plan.md`.
3. Review and optionally refine the plan (see the `loop-refine-plan` skill).
4. Pass the plan to `start-rlcr-loop` to begin iterative development.

## Notes

- The generation mode is controlled by `gen_plan_mode` in `config/default_config.json` (default: `discussion`).
- The `alternative_plan_language` config key can be set to generate plans in a non-default language, but all content in this project must remain in English.
- The generated plan file is the primary input to the RLCR loop. Keep it focused and well-scoped.
