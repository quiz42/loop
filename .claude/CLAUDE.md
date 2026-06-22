# humanize-loop Introduction
This is a Claude Code plugin that provides iterative development with Codex review. Use `/start-rlcr-loop` to start an RLCR loop, and `/cancel-rlcr-loop` to cancel an active loop.

# humanize-loop Project Rules
- Everything about this project, including but not limited to implementations, comments, tests and documentation should be in English. No emoji or CJK characters are allowed.
- If version bump is required, please bump them in three files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `README.md` (the "Version" line).
- Version number must be in format of `X.Y.Z` where X/Y/Z are numeric. Version MUST NOT include anything other than `X.Y.Z`.
- The plan template in `commands/gen-plan.md` (Plan Structure section) and `prompt-template/plan/gen-plan-template.md` are intentionally kept in sync. When modifying either file, ensure both are updated to maintain consistency.
- Changes to `prompt-template/plan/gen-plan-template.md` must also be reflected in the Plan Structure section of `commands/gen-plan.md`.