# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, or
- **`CONTEXT-MAP.md`** at the repo root if it exists — it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in. In multi-context repos, also check `src/<context>/docs/adr/` for context-scoped decisions.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

This repo is **single-context**:

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-local-first-static-proof-distribution.md
│   ├── 0002-conservative-verdict-derivation.md
│   └── 0003-python-for-proof-layer.md
├── hooks/
└── scripts/
```

For reference, a multi-context repo (signalled by `CONTEXT-MAP.md` at the root) would instead look like:

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

`CONTEXT.md` currently covers the Proof of Loop evidence layer: Loop Run, Round,
Head Commit, Reviewed Commit, Terminal State, Acceptance Criterion, Evidence Item,
Proof Bundle, Run ID, Proof ID, Delivery Verdict, Finding, Verification Profile,
Proof Integrity, Loop-Verified, Replay, and Public Profile. Each entry carries an
_Avoid_ line naming the synonyms not to use — respect those.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Related design records

Beyond `CONTEXT.md` and the ADRs, the Proof of Loop work has three longer records
under `docs/`. They are not glossaries, but they are the authority for their own
scope:

- `proof-of-loop-mvp-spec.md` — the implementable specification
- `proof-of-loop-mvp-decisions.md` — decisions D1-D17; governs the draft wherever they differ
- `proof-of-loop-mvp-design.md` — the original draft, superseded section by section

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0002 (conservative verdict derivation) — but worth reopening because…_
