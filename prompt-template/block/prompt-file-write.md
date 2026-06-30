# Writing to prompt files is blocked

Writing to `.claude/` prompt files during an active RLCR loop is not allowed.

Prompt files are managed by the loop framework. Do not modify them directly.
