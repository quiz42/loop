# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Other labels in this repo

Alongside the triage roles, this repo uses three descriptive families inherited
from upstream's vocabulary. They are orthogonal to triage state:

- `type-*` — `type-feature`, `type-documentation`, `type-infrastructure`
- `area-*` — `area-cli`, `area-docs`, and the other subsystem areas
- `phase-*` — position in the implementation timeline

## Labels must exist before use

This fork started with only GitHub's nine default labels; every label above was
created here explicitly. Before applying a label, confirm it exists:

```bash
gh label list --repo quiz42/loop --limit 100
```

`gh issue create --label` silently drops unknown labels while still exiting 0, so
read labels back after creating an issue. See `docs/agents/issue-tracker.md`.
