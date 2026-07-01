# Command: /loop:gen-plan

Generate a structured implementation plan from an idea document. The output `PLAN.md` is the primary input for `/loop:start-rlcr-loop` and drives all agent activity during the loop.

> **Note:** The **Plan Structure** section below is kept in sync with
> `prompt-template/plan/gen-plan-template.md`. If you update the plan structure
> in either file, update the other to match.

## Usage

```
/loop:gen-plan [options]
```

Internally runs:

```
loop gen-plan [--input IDEA.md] [--output PLAN.md] [--title TITLE]
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--input FILE` | `IDEA.md` | Path to the idea document produced by `/loop:gen-idea` |
| `--output FILE` | `PLAN.md` | Path where the generated plan is written |
| `--title TITLE` | Derived from input | Title used as the H1 heading in the generated plan |

## What It Does

1. Reads the idea document (`--input`).
2. Expands it into a full implementation plan with goals, tasks, acceptance criteria, and constraints.
3. Writes the result to `--output` (default `PLAN.md`).

The generated `PLAN.md` is consumed directly by `/loop:start-rlcr-loop`.

## Plan Structure

Every generated plan follows this structure:

```markdown
# <Title>

## Overview
Brief description of what will be built and why.

## Goals
- [ ] Goal 1 — short statement of a verifiable outcome
- [ ] Goal 2
- ...

## Tasks
Ordered list of implementation tasks that collectively satisfy the goals.

1. Task description (maps to one or more goals)
2. ...

## Acceptance Criteria
Explicit, testable conditions that must be true for the plan to be considered complete.

- Criterion 1
- Criterion 2

## Constraints
Any technical, architectural, or process constraints that must be respected.

- Constraint 1

## Out of Scope
What is explicitly not part of this plan.
```

## Example Usage

```
# Generate a plan from the default IDEA.md
/loop:gen-plan

# Specify a custom input and output
/loop:gen-plan --input ideas/auth-refactor.md --output plans/auth-plan.md

# Override the title
/loop:gen-plan --input IDEA.md --output PLAN.md --title "Dark Mode Implementation Plan"
```

## Expected Output

```
[loop] Reading idea from IDEA.md...
[loop] Generating implementation plan...
[loop] Plan written to PLAN.md (7 goals, 12 tasks, 5 acceptance criteria)
```
