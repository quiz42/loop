# Command: /loop:gen-idea

Generate a structured idea document from a plain-language description. The output is a markdown file that captures the concept, motivation, and high-level approach — ready to be refined into a full plan with `/loop:gen-plan`.

## Usage

```
/loop:gen-idea DESCRIPTION [options]
```

Internally runs:

```
loop gen-idea DESCRIPTION [--output FILE] [--title TITLE]
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `DESCRIPTION` | Yes | Plain-language description of the idea. Can be a short phrase or a paragraph. Quote multi-word descriptions. |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--output FILE` | `IDEA.md` | Path where the generated idea document is written |
| `--title TITLE` | Derived from description | Title used as the H1 heading in the generated document |

## What It Does

1. Accepts the free-text description and expands it into a structured idea document.
2. The document includes: title, summary, motivation/problem statement, proposed approach, and open questions.
3. Writes the result to `--output` (default `IDEA.md`).

The generated idea document is the expected input for `/loop:gen-plan`.

## Example Usage

```
# Quick idea from a short phrase
/loop:gen-idea "add dark mode support to the dashboard"

# Provide an explicit title and output path
/loop:gen-idea "refactor auth layer to use JWT refresh tokens" \
  --title "JWT Refresh Token Auth Refactor" \
  --output ideas/auth-refactor.md
```

## Expected Output

```
[loop] Generating idea document...
[loop] Idea written to IDEA.md
```

**IDEA.md** (example structure):

```markdown
# Add Dark Mode Support to the Dashboard

## Summary
Introduce a dark colour scheme for the dashboard UI, toggled by a user preference.

## Motivation
Users working in low-light environments have requested a dark mode option to reduce eye strain.

## Proposed Approach
- Add a `theme` field to user preferences (light / dark / system)
- Implement CSS custom properties for colour tokens
- Persist the preference in local storage and sync to the user profile

## Open Questions
- Should the default follow the OS preference (`prefers-color-scheme`)?
- Which components need the most urgent theming work?
```
