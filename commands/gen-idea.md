# Command: /loop:gen-idea

Generate a structured idea document from a plain-language description. The output is a markdown file that captures the concept, target outcome, and a deterministic directed-exploration scaffold that is ready to be refined into a full plan with `/loop:gen-plan`.

## Usage

```
/loop:gen-idea DESCRIPTION [options]
```

Internally runs:

```
loop gen-idea DESCRIPTION [--n COUNT] [--output FILE] [--title TITLE]
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `DESCRIPTION` | Yes | Plain-language description of the idea. Can be a short phrase or a paragraph. Quote multi-word descriptions. |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--n COUNT` | `6` | Number of directed exploration slots recorded in the idea draft |
| `--output FILE` | `.loop/ideas/idea-<slug>.md` | Path where the generated idea document is written |
| `--title TITLE` | Derived from description | Title used as the H1 heading in the generated document |

## What It Does

1. Accepts the free-text description and expands it into a structured idea document.
2. The document includes: title, idea statement, target outcome, directed exploration slots, users, acceptance criteria, and open questions.
3. Writes the result to `--output` (default `.loop/ideas/idea-<slug>.md`).

The generated idea document is the expected input for `/loop:gen-plan`.

## Example Usage

```
# Quick idea from a short phrase
/loop:gen-idea "add dark mode support to the dashboard"

# Request a smaller exploration set
/loop:gen-idea "add dark mode support to the dashboard" --n 3

# Provide an explicit title and output path
/loop:gen-idea "refactor auth layer to use JWT refresh tokens" \
  --title "JWT Refresh Token Auth Refactor" \
  --output ideas/auth-refactor.md
```

## Expected Output

```
Wrote idea draft to .loop/ideas/idea-add-dark-mode-support-to-the-dashboard.md
```

**IDEA.md** (example structure):

```markdown
# Add Dark Mode Support to the Dashboard

Generated: 2026-07-13T00:00:00Z

## Idea

Introduce a dark colour scheme for the dashboard UI, toggled by a user preference.

## Target Outcome

Define a focused change that can be reviewed through the RLCR workflow and verified with clear acceptance criteria.

## Directed Exploration

- Requested directions: 3

### Primary: Repo-Grounded Path 1

- Rationale: Explore a distinct implementation angle against the current repository context.
- Objective Evidence: To be filled during planning with concrete files, patterns, and risks.

## Open Questions
- What constraints, integrations, or compatibility requirements must the plan preserve?
- Which files or commands prove the change works?
```
