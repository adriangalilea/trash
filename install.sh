#!/bin/bash

# Modern macOS trash commands installer
set -e

INSTALL_DIR="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🗑️  Installing mac-trash-plugins..."

# Create ~/.local/bin if it doesn't exist (XDG standard)
mkdir -p "$INSTALL_DIR"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo "📝 Adding ~/.local/bin to PATH..."
    
    # Detect shell
    if [ -n "$ZSH_VERSION" ]; then
        SHELL_RC="$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
        SHELL_RC="$HOME/.bashrc"
    else
        SHELL_RC="$HOME/.zshrc"  # Default to zsh on modern macOS
    fi
    
    # Add to PATH if not already there
    if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$SHELL_RC" 2>/dev/null; then
        echo '' >> "$SHELL_RC"
        echo '# mac-trash-plugins' >> "$SHELL_RC"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
        echo "✅ Added to $SHELL_RC"
    fi
fi

# Create symlinks
for cmd in trash-list trash-restore trash-empty; do
    if [ -f "$INSTALL_DIR/$cmd" ]; then
        echo "⚠️  $cmd already exists, removing old version..."
        rm -f "$INSTALL_DIR/$cmd"
    fi
    ln -sf "$SCRIPT_DIR/$cmd" "$INSTALL_DIR/$cmd"
    echo "✅ Installed $cmd"
done

echo ""
echo "✨ Installation complete!"
echo ""
echo "Available commands:"
echo "  trash-list     - List files in trash"
echo "  trash-restore  - Restore files from trash"
echo "  trash-empty    - Empty the trash"
echo ""
echo "🔄 Restart your terminal or run: source ~/.zshrc"