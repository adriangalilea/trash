# trash

macOS Trash CLI with a real Put Back. One command, native `~/.Trash`.

```
trash file.txt                 # move to Trash, origin recorded
trash list                     # what's in the Trash, since when, from where
trash restore file.txt         # back to where it came from
trash restore file.txt ~/tmp   # ...or into a chosen directory
trash empty                    # empty, with confirmation (-f skips)
```

## Why

Apple ships `/usr/bin/trash`: perfect Finder integration, zero introspection.
No list, no restore, no empty. `trash-cli` has the commands but refuses the
native `~/.Trash`, so your files vanish from Finder and Put Back breaks.

This tool is both: it moves files with `FileManager.trashItem`, the same API
Finder uses, and stamps each item with an xattr
(`com.adriangalilea.trash.origin`) holding its original absolute path. That
xattr is what `restore` reads to put a file back where it lived. Every trash
prints a `trashed: <origin>` breadcrumb, so your shell history doubles as an
undo log.

It deliberately shadows `/usr/bin/trash` (install to a PATH dir that wins):
the base case is identical by construction, and if the binary is ever
missing, PATH falls through to Apple's and you lose only the extras.

## Install

```sh
mise run install     # builds and installs to ~/.local/bin/trash
```

Or without mise: `swift build -c release && install -m 755 .build/release/trash ~/.local/bin/`

## Semantics worth knowing

- Subcommand names always win: a file literally named `list` is trashed with
  `trash ./list` or `trash -- list`. Deterministic, and the dangerous
  direction (a filename silently hijacking a subcommand) cannot happen.
- `restore` never overwrites, and screams if the original directory is gone
  or the item was trashed by something else (no recorded origin): pass a
  destination directory in those cases, or use Finder's Put Back.
- Duplicate names in the Trash make `restore` refuse rather than guess.
- Home-volume Trash only. Items trashed on external volumes live in that
  volume's `.Trashes` and stay Finder's business.

## Requirements

macOS 13+. Built with SwiftPM; no dependencies.
