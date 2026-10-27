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
brew install --cask adriangalilea/tap/trash
```

That installs `trash.app` and links the `trash` command from inside it.
Installed as the old Homebrew formula? `brew uninstall trash` first.

## Reading the Trash needs Full Disk Access

Moving things into the Trash works from anywhere. Reading it (`list`,
`restore`, `empty`) doesn't: macOS lets only a process with Full Disk Access
read `~/.Trash`, grants it to the app a command runs in (your terminal), never
to the command, and never asks. Without it, `trash list` says so and exits 1;
it never shows an unreadable Trash as empty.

So `trash` reads the Trash itself first, and only when macOS refuses does it
run the same operation again as `trash.app`: opened through LaunchServices,
the app is its own app to macOS and holds its own grant, does the one
operation, hands back the answer and exits. No background process, and one
implementation either way. The first time it needs the grant, `trash.app`
asks for it (swift-utils PermissionGrants: its window says what and why, its
button opens the switch, and it closes itself the moment the switch is on),
then the command you ran finishes. A terminal that already has Full Disk
Access never involves it.

## From source

```sh
swift build -c release   # .build/release/trash: the plain command
```

The plain command works wherever your terminal may read the Trash. The app
needs a stable signature, because macOS ties its grant to it (an unsigned
build's grant is lost at the next rebuild): with a certificate of your own,
`SIGN_ID=<identity> mise run install` builds `trash.app` into
`~/Applications` and links `trash` into `~/.local/bin`.

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

macOS 26+. Built with SwiftPM; one dependency, swift-utils' `PermissionGrants`
for trash.app's grant. `TrashKit` is everything
done to the Trash (no printing, no exits); the `trash` target is the command's
words and the run-as-app hop (`Sources/trash/AsApp.swift`).
