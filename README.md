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
prints a `trashed: <origin>` breadcrumb to stderr, so your terminal doubles
as an undo log while stdout stays byte-identical to `/usr/bin/trash` (empty):
scripts and pipes never see a difference. When macOS renames on collision the
breadcrumb says so: `trashed: ~/a/dup.txt (in Trash as 'dup.txt 14-27-01.txt')`.

It deliberately shadows `/usr/bin/trash` (install to a PATH dir that wins):
the base case is identical by construction, and if the binary is ever
missing, PATH falls through to Apple's and you lose only the extras.

## It empties what Finder can't

macOS hides AppleDouble `._` metadata files in the Trash from Finder and
from every app built on Foundation's directory listing. A Trash can hold
thousands of them - typically left behind after deleting folders that once
lived on exFAT/FAT drives - while Finder shows it empty and greys out
Empty Trash, keeping the bytes on disk indefinitely. `trash list` reports
them, `trash empty` deletes them with everything else, and the
confirmation states both counts. Check yours: `ls -A ~/.Trash` next to an
"empty" Trash can be a surprise.

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
- Duplicate names don't happen: macOS renames on collision inside the Trash
  (`dup.txt` then `dup.txt 14-27-01-327.txt`), and each item restores to its
  true origin regardless of the trash-side rename. If a duplicate somehow
  appears anyway, `restore` refuses rather than guesses.
- Home-volume Trash only. Items trashed on external volumes live in that
  volume's `.Trashes` and stay Finder's business.

## Requirements

macOS 13+. Built with SwiftPM; no dependencies.
