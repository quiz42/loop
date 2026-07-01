#!/usr/bin/env bash
# Uninstall loop plugin from local Claude Code and Codex installations

set -e

PLUGIN_NAME="loop"

echo "=== loop uninstaller ==="
echo ""

removed=0

# Remove from Claude Code
for dir in \
    "$HOME/.claude-code/plugins/$PLUGIN_NAME" \
    "$HOME/.config/claude-code/plugins/$PLUGIN_NAME" \
    "$HOME/Library/Application Support/claude-code/plugins/$PLUGIN_NAME"; do
    if [ -L "$dir" ] || [ -d "$dir" ]; then
        echo "Removing Claude Code installation: $dir"
        rm -rf "$dir"
        echo "✓ Claude Code plugin removed"
        removed=$((removed + 1))
    fi
done

# Remove from Codex
for dir in \
    "$HOME/.codex/plugins/$PLUGIN_NAME" \
    "$HOME/.config/codex/plugins/$PLUGIN_NAME"; do
    if [ -L "$dir" ] || [ -d "$dir" ]; then
        echo "Removing Codex installation: $dir"
        rm -rf "$dir"
        echo "✓ Codex plugin removed"
        removed=$((removed + 1))
    fi
done

if [ "$removed" -eq 0 ]; then
    echo "No loop installations found. Nothing to remove."
else
    echo ""
    echo "✓ loop uninstalled ($removed location(s) cleaned up)"
    echo "  Note: config/ and project files are not deleted."
fi
