#!/usr/bin/env bash
# One-click local install script for loop plugin
# Installs loop into Claude Code and Codex from local/cloned repository

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_NAME="loop"

echo "=== loop local installer ==="
echo "Plugin root: $PLUGIN_ROOT"
echo ""

# Detect Claude Code plugin directory
CLAUDE_PLUGIN_DIR=""
if [ -d "$HOME/.claude-code/plugins" ]; then
    CLAUDE_PLUGIN_DIR="$HOME/.claude-code/plugins"
elif [ -d "$HOME/.config/claude-code/plugins" ]; then
    CLAUDE_PLUGIN_DIR="$HOME/.config/claude-code/plugins"
elif [ -d "$HOME/Library/Application Support/claude-code/plugins" ]; then
    CLAUDE_PLUGIN_DIR="$HOME/Library/Application Support/claude-code/plugins"
fi

# Detect Codex plugin directory
CODEX_PLUGIN_DIR=""
if [ -d "$HOME/.codex/plugins" ]; then
    CODEX_PLUGIN_DIR="$HOME/.codex/plugins"
elif [ -d "$HOME/.config/codex/plugins" ]; then
    CODEX_PLUGIN_DIR="$HOME/.config/codex/plugins"
fi

# Install to Claude Code
if [ -n "$CLAUDE_PLUGIN_DIR" ]; then
    echo "✓ Found Claude Code plugin directory: $CLAUDE_PLUGIN_DIR"
    TARGET="$CLAUDE_PLUGIN_DIR/$PLUGIN_NAME"
    
    if [ -L "$TARGET" ] || [ -d "$TARGET" ]; then
        echo "  Removing existing installation..."
        rm -rf "$TARGET"
    fi
    
    echo "  Creating symlink: $TARGET -> $PLUGIN_ROOT"
    ln -s "$PLUGIN_ROOT" "$TARGET"
    echo "  ✓ Claude Code installation complete"
else
    echo "⚠ Claude Code plugin directory not found"
    echo "  Expected locations:"
    echo "    - ~/.claude-code/plugins"
    echo "    - ~/.config/claude-code/plugins"
    echo "    - ~/Library/Application Support/claude-code/plugins (macOS)"
fi

echo ""

# Install to Codex
if [ -n "$CODEX_PLUGIN_DIR" ]; then
    echo "✓ Found Codex plugin directory: $CODEX_PLUGIN_DIR"
    TARGET="$CODEX_PLUGIN_DIR/$PLUGIN_NAME"
    
    if [ -L "$TARGET" ] || [ -d "$TARGET" ]; then
        echo "  Removing existing installation..."
        rm -rf "$TARGET"
    fi
    
    echo "  Creating symlink: $TARGET -> $PLUGIN_ROOT"
    ln -s "$PLUGIN_ROOT" "$TARGET"
    echo "  ✓ Codex installation complete"
else
    echo "⚠ Codex plugin directory not found"
    echo "  Expected locations:"
    echo "    - ~/.codex/plugins"
    echo "    - ~/.config/codex/plugins"
fi

echo ""

# Make scripts executable
echo "Making scripts executable..."
chmod +x "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/scripts/*.py 2>/dev/null || true
echo "✓ Scripts are executable"

echo ""
echo "=== Installation summary ==="
if [ -n "$CLAUDE_PLUGIN_DIR" ]; then
    echo "  ✓ Claude Code: installed at $CLAUDE_PLUGIN_DIR/$PLUGIN_NAME"
    echo "    Restart Claude Code and run: /monitor"
fi
if [ -n "$CODEX_PLUGIN_DIR" ]; then
    echo "  ✓ Codex: installed at $CODEX_PLUGIN_DIR/$PLUGIN_NAME"
fi

if [ -z "$CLAUDE_PLUGIN_DIR" ] && [ -z "$CODEX_PLUGIN_DIR" ]; then
    echo "  ✗ No plugin directories found. Install Claude Code or Codex first."
    exit 1
fi

echo ""
echo "Next steps:"
echo "  1. Restart Claude Code / Codex"
echo "  2. Verify with: /monitor (Claude Code) or codex /monitor (Codex)"
echo "  3. Review config at: config/default_config.json"
echo ""
echo "To uninstall, run: bash scripts/uninstall-local.sh"
