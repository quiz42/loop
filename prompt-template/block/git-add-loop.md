# Git Add Blocked: .loop Protection

The `.loop/` directory contains local loop state that should NOT be committed.
This directory is already listed in `.gitignore`.

Your command was blocked because it would add .loop files to version control.

## Allowed Commands

Use specific file paths instead of broad patterns:

    git add <specific-file>
    git add src/
    git add -p  # patch mode

## Blocked Commands

These commands are blocked when .loop exists:

    git add .loop      # direct reference
    git add -A             # adds all including .loop
    git add --all          # adds all including .loop
    git add .              # may include .loop if not gitignored
    git add -f .           # force bypasses gitignore

## Adding .loop to .gitignore

If you need to add `.loop*` to `.gitignore`, follow these steps:

1. Edit `.gitignore` to append `.loop*`
2. Run: `git add .gitignore`
3. Run: `git commit -m "Add loop local folder into gitignore"`

IMPORTANT: The commit message must NOT contain the literal string ".loop" to avoid triggering this protection.
