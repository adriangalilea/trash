#!/bin/bash

# Uninstaller for mac-trash-plugins
set -e

INSTALL_DIR="$HOME/.local/bin"

echo "🗑️  Uninstalling mac-trash-plugins..." >&2

# Remove symlinks
for cmd in trash-list trash-restore trash-empty; do
    if [ -L "$INSTALL_DIR/$cmd" ]; then
        rm -f "$INSTALL_DIR/$cmd"
        echo "✅ Removed $cmd"
    else
        echo "⚠️  $cmd not found"
    fi
done

# Optionally remove PATH entry
echo ""
read -p "Remove PATH entry from shell config? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Try both .zshrc and .bashrc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$rc" ]; then
            # Remove the PATH line and comment
            sed -i '' '/# mac-trash-plugins/d' "$rc" 2>/dev/null || true
            sed -i '' '/export PATH="\$HOME\/.local\/bin:\$PATH"/d' "$rc" 2>/dev/null || true
            echo "✅ Cleaned $rc"
        fi
    done
fi

echo ""
echo "✨ Uninstall complete!"
echo "🔄 Restart your terminal to apply changes"