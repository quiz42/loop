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
2. Expands it into a full implementation plan with goal description, acceptance criteria, path boundaries, task routing, deliberation summary, and verification commands.
3. Writes the result to `--output` (default `PLAN.md`).

The generated `PLAN.md` is consumed directly by `/loop:start-rlcr-loop`.

## Plan Structure

Every generated plan follows this structure:

```markdown
# <Title> Implementation Plan

## Source Idea
Original idea content used as the planning input.

## Goal Description
Clear, direct description of what needs to be accomplished.

## Acceptance Criteria
Each criterion includes positive and negative tests for deterministic verification.

## Path Boundaries
Upper bound, lower bound, and allowed choices for implementation scope.

## Feasibility Hints and Suggestions
Conceptual implementation path and relevant repository references.

## Dependencies and Sequence
Milestones and dependency order.

## Implementation Steps
Ordered local work sequence.

## Task Breakdown
Task table with `coding` or `analyze` routing tags.

## Claude-Codex Deliberation
Agreement and convergence summary.

## Pending User Decisions
Explicit decisions that need owner input, or `None`.

## Implementation Notes
Code style and workflow notes for implementers.

## Verification
Commands that prove the implementation works.
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
Wrote implementation plan to PLAN.md
```
