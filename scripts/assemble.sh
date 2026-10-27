#!/bin/sh
# trash.app, assembled by hand (no Xcode), for `mise run install` and the
# release alike, so the app you run and the app you ship can never diverge.
#   scripts/assemble.sh <destination.app>     (VERSION in the environment)
# The bundle is the command itself (Contents/MacOS/trash) wearing an identity
# macOS can grant Full Disk Access to: when a terminal may not read the Trash,
# the command runs again as this app (Sources/trash/AsApp.swift).
set -e
dest="$1"
[ -n "$dest" ] || { echo "usage: scripts/assemble.sh <destination.app>"; exit 1; }
[ -n "$VERSION" ] || { echo "VERSION is not set"; exit 1; }
rm -rf "$dest"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
ditto .build/release/trash "$dest/Contents/MacOS/trash"
ditto Resources/trash.icns "$dest/Contents/Resources/trash.icns"
# The glass icon (CFBundleIconName); the icns above is its flat fallback.
ditto Resources/Assets.car "$dest/Contents/Resources/Assets.car"
sed -e "s|__VERSION__|$VERSION|g" bundle/Info.plist.in > "$dest/Contents/Info.plist"
