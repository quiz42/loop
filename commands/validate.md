# Command: /loop:validate

Validate input and output files for loop planning commands. This command exposes the same checks as the legacy validation shell wrappers through the main `loop` CLI.

## Usage

```
/loop:validate <subcommand> [options]
```

Internally runs:

```
loop validate gen-idea --output IDEA.md [--input SOURCE.md] [--allow-overwrite] [--check-output-content]
loop validate gen-plan --input IDEA.md --output PLAN.md [--allow-overwrite] [--check-output-content]
loop validate refine-plan --input PLAN.md --output REFINED.md [--allow-overwrite] [--check-output-content]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `gen-idea` | Validate optional source text and the target idea output path |
| `gen-plan` | Validate an idea file and the target plan output path |
| `refine-plan` | Validate an annotated plan file and the target refined plan output path |

## Example Usage

```
# Confirm an idea output path is available
/loop:validate gen-idea --output docs/idea.md

# Validate a generated idea before creating a plan
/loop:validate gen-plan --input docs/idea.md --output docs/plan.md

# Validate a refined plan output path
/loop:validate refine-plan --input docs/plan.md --output docs/refined-plan.md

# Check that an existing generated file has content
/loop:validate gen-plan --input docs/idea.md --output docs/plan.md --check-output-content
```
