# mac-trash-plugins

## The Problem

> "macOS native `trash` cli command, could have been the perfect `rm` replacement.

- ✅ Integrates perfectly with Finder native Trash
- ✅ "Put Back" remembers original locations
- ✅ Protects against accidental `rm -rf` disasters
- ❌ No way to list Trash contents from terminal
- ❌ No way to restore specific files
- ❌ No way to empty Trash without GUI

This forced us into terrible workarounds:
- Using dangerous `rm -rf` (no undo!)
- Installing `trash-cli` that refuses to support native macOS `Trash`
- Having to switch between Finder & cli just to check/restore/empty what's in Trash

## The Solution

This project adds the missing CLI commands while keeping all the native macOS Trash benefits.

## Version

**v0.1.0** - Shell + AppleScript implementation

## Features

- `trash-list` - List files in Trash
- `trash-restore <filename>` - Restore files from Trash  
- `trash-empty` - Empty Trash with confirmation

## Installation

```bash
./install.sh
```

This will:
- Install commands to `~/.local/bin`
- Add `~/.local/bin` to your PATH (if needed)
- Create symlinks to the scripts

## Uninstall

```bash
./uninstall.sh
```

## Usage

### trash-list
List all files currently in the Trash:

```bash
$ trash-list
SpotifyInstaller.zip -> /Users/username/.Trash/SpotifyInstaller.zip
old-project -> /Users/username/.Trash/old-project/
document.pdf -> /Users/username/.Trash/document.pdf
```

When Trash is empty:
```bash
$ trash-list
Trash is empty
```

### trash-restore
Restore files from Trash to current directory or specified location:

```bash
# Restore to current directory
$ trash-restore document.pdf
Restored: document.pdf to /Users/username/Documents

# Restore to specific location
$ trash-restore old-project ~/Projects
Restored: old-project to /Users/username/Projects

# Show available files if none specified
$ trash-restore
Usage: trash-restore <filename> [destination]

Available files in Trash:
SpotifyInstaller.zip -> /Users/username/.Trash/SpotifyInstaller.zip
document.pdf -> /Users/username/.Trash/document.pdf
```

### trash-empty
Empty the Trash with confirmation:

```bash
$ trash-empty
Are you sure you want to empty the Trash? [y/N] y
Trash emptied

# Cancel by pressing N or Enter
$ trash-empty
Are you sure you want to empty the Trash? [y/N] n
Cancelled
```

## Current Limitations

**v0.1.0 limitations:**
- **No original path detection** - Files can only be restored to current directory or manually specified location
- **No "Put Back" support** - Cannot restore to original location automatically
- **No metadata access** - Cannot see when files were trashed
- **Basic name matching** - May have issues with duplicate filenames

These limitations exist because AppleScript doesn't expose trash metadata. Full functionality requires native macOS APIs, planned for v1.0.0.

## Requirements

- macOS (uses AppleScript)
- No external dependencies

## How it works

These commands use AppleScript to interact with Finder's Trash, ensuring full compatibility with macOS Trash features like "Put Back".

## Why mac-trash-plugins?

### Comparison with other tools

**trash-cli** (cross-platform)
- ❌ Uses `~/.local/share/Trash/` - files don't appear in macOS Trash
- ❌ No Finder integration or "Put Back" support
- ❌ Can't be configured to use `~/.Trash`
- ✅ Has CLI commands (list, restore, empty)

**Native macOS `trash` command**
- ✅ Full native Trash integration
- ❌ No CLI commands for listing or restoring

**mac-trash-plugins**
- ✅ Best of both worlds: native macOS Trash + CLI commands
- ✅ Files stay in `~/.Trash` with full Finder integration
- ✅ Adds missing CLI features to native Trash
- ✅ No dependencies or complex configuration

### The Problem

I migrated from `trash-cli` because I wanted my trashed files to appear in the macOS Trash where they belong. Having files in a separate `~/.local/share/Trash/` location breaks the native experience - you can't see them in Finder, can't use "Put Back", and the Trash icon doesn't reflect what's actually trashed.

This project extends the native macOS Trash with the CLI conveniences of `trash-cli` while keeping everything in the proper `~/.Trash` location.

## Roadmap

### v0.1.0 (Current)
- ✅ Basic Trash operations via AppleScript
- ✅ Shell script implementation
- ✅ Easy install/uninstall

### v1.0.0 (Future)
- Native Swift CLI implementation
- Direct FileManager API access
- Single compiled binary
- Faster performance
- Additional features:
  - `trash-info <file>` - Show file metadata (deletion date, original path)
  - `trash-restore --all` - Batch restore operations
  - `trash-prune --days 30` - Remove items older than N days
  - Better error handling and progress reporting
