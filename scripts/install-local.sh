#!/usr/bin/env bash
# One-click local install script for loop plugin and CLI
# Installs loop into Claude Code and Codex plugin directories

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_NAME="loop"

echo "=== loop local installer ==="
echo "Plugin root: $PLUGIN_ROOT"
echo ""

# Check for uv
if ! command -v uv &> /dev/null; then
    echo "⚠ uv not found. Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$PATH"
    
    if ! command -v uv &> /dev/null; then
        echo "✗ uv installation failed. Please install manually:"
        echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
        exit 1
    fi
    echo "✓ uv installed"
fi

# Initialize uv environment (creates .venv if it doesn't exist)
echo ""
echo "Setting up Python environment with uv..."
cd "$PLUGIN_ROOT"
uv venv
uv sync --no-install-project
echo "✓ Python environment ready"

# Install loop CLI to ~/.local/lib/loop/
LOOP_INSTALL_DIR="$HOME/.local/lib/loop"
echo ""
echo "Installing loop CLI to $LOOP_INSTALL_DIR..."
mkdir -p "$LOOP_INSTALL_DIR"

# Copy Python scripts and libraries
cp -r "$PLUGIN_ROOT/scripts/"* "$LOOP_INSTALL_DIR/"
echo "✓ loop scripts installed"

# Create wrapper script at ~/.local/bin/loop
LOOP_BIN="$HOME/.local/bin/loop"
mkdir -p "$HOME/.local/bin"
cat > "$LOOP_BIN" <<'EOF'
#!/usr/bin/env bash
# loop CLI wrapper — calls the installed Python script
set -euo pipefail
LOOP_LIB="$HOME/.local/lib/loop"
exec python3 "$LOOP_LIB/loop.py" "$@"
EOF
chmod +x "$LOOP_BIN"
echo "✓ loop command installed to $LOOP_BIN"

# Verify CLI installation
if command -v loop &> /dev/null; then
    echo "  loop command: $(which loop)"
else
    echo "⚠ 'loop' not in PATH yet. Add ~/.local/bin to PATH:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

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
    echo "  ✓ Claude Code plugin installed"
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
    echo "  ✓ Codex plugin installed"
else
    echo "⚠ Codex plugin directory not found"
    echo "  Expected locations:"
    echo "    - ~/.codex/plugins"
    echo "    - ~/.config/codex/plugins"
fi

echo ""
echo "=== Installation summary ==="
echo "  ✓ Python environment: .venv/ (managed by uv)"
if command -v loop &> /dev/null; then
    echo "  ✓ loop CLI: available in PATH"
else
    echo "  ⚠ loop CLI: add ~/.local/bin to PATH"
fi
if [ -n "$CLAUDE_PLUGIN_DIR" ]; then
    echo "  ✓ Claude Code plugin: $CLAUDE_PLUGIN_DIR/$PLUGIN_NAME"
fi
if [ -n "$CODEX_PLUGIN_DIR" ]; then
    echo "  ✓ Codex plugin: $CODEX_PLUGIN_DIR/$PLUGIN_NAME"
fi

echo ""
echo "Next steps:"
echo "  1. Activate environment: source .venv/bin/activate"
echo "  2. Or ensure ~/.local/bin is in PATH for 'loop' command"
echo "  3. Verify CLI: loop monitor"
echo "  4. Use in Claude Code: restart and run /monitor"
echo ""
echo "To uninstall, run: bash scripts/uninstall-local.sh"
