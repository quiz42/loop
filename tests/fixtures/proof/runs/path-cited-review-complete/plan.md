# Skip Implementation Mode

This RLCR loop was started with `--skip-impl` flag, which skips the implementation phase
and goes directly to code review.

No implementation plan was provided - this is expected for skip-impl mode.

The loop will:
1. Run `codex review` on the current branch changes
2. If issues are found, Claude will fix them
3. When no issues remain, enter finalize phase

