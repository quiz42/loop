# AGENTS.md

Guidance for coding agents working in this repository. This is the primary agent
instruction file; `CLAUDE.md` points here.

## Repository fork layout

Development happens on the **`quiz42/loop`** fork (`origin`). `ProofofShip/loop`
is `upstream` and receives changes only through a manually opened merge request
once work is complete. The `upstream` push URL is deliberately disabled locally;
do not re-enable it or push there.

## Commit language

All committed content is English: file contents, commit messages, PR and issue
descriptions. Design discussion may happen in another language, but anything
that lands in the repository or on the tracker is translated first.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on the `quiz42/loop` fork, driven by the `gh` CLI.
See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the root plus `docs/adr/`. See
`docs/agents/domain.md`.
