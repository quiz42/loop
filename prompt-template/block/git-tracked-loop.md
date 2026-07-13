# Tracked Loop State Blocked

Detected tracked or staged files under `.loop/`.

These files are local Loop state and must remain outside version control.

## Required Fix

1. Remove Loop state from the index:

       git rm --cached -r .loop

2. Keep only real project files staged.
3. Retry the stop action after the local state is no longer tracked.

## Important

- Do NOT use `git add -f` on Loop state files.
- Do NOT commit RLCR trackers, round summaries, contracts, or cancel/finalize markers.
