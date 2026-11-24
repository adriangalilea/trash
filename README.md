# trash

macOS Trash CLI with a real Put Back. One command, native `~/.Trash`.

```
trash file.txt folder/           # move to Trash, origin recorded
trash --list                     # what's in the Trash, since when, from where
trash --restore file.txt         # back to where it came from
trash --restore file.txt ~/tmp   # ...or into a chosen directory
trash --empty                    # empty, with confirmation (-f skips)
trash --check                    # does trash work here right now, with nobody needed
```

Every word is a file, exactly as with Apple's `/usr/bin/trash`: `trash list`
trashes a file named `list`. Everything else is a flag. `trash --help` is the
full description, `trash --skill install` gives it to Claude Code and Codex
as a skill, and `--list` and `--check` answer `--json`.

## Why

Apple ships `/usr/bin/trash`: perfect Finder integration, zero introspection.
No list, no restore, no empty. `trash-cli` has the commands but refuses the
native `~/.Trash`, so your files vanish from Finder and Put Back breaks.

This tool is both: it moves files with `FileManager.trashItem`, the same API
Finder uses, stamps each item it moves with where it came from, and also
reads macOS's own Put Back record, the one Finder's Put Back uses. So it
restores what it trashed and what Finder or any other tool trashed. Every trash
prints a `trashed: <origin>` breadcrumb to stderr, so your terminal doubles
as an undo log while stdout stays byte-identical to `/usr/bin/trash` (empty):
scripts and pipes never see a difference. When macOS renames on collision the
breadcrumb says so: `trashed: ~/a/dup.txt (in Trash as 'dup.txt 14-27-01.txt')`.

It deliberately shadows `/usr/bin/trash` (install to a PATH dir that wins):
the base case is identical by construction, and if the binary is ever
missing, PATH falls through to Apple's and you lose only the extras.

## Where Put Back lives

macOS keeps it in `~/.Trash/.DS_Store`, a B-tree of records keyed by each
item's name in the Trash: `ptbL` is the folder it left, `ptbN` the name it
had there (so an item macOS renamed on a collision still goes back under its
own name). `trash` reads that file by its structure and never writes it.
Three things about it are worth knowing:

- macOS writes the record only for the first item a process trashes, and
  loses some even then. Apple's `/usr/bin/trash a b c` leaves `b` and `c`
  without a Put Back, and so does `trash a b c`: Finder's Put Back works for
  its first item only. A process per path would record most of the rest at
  about 70 ms a path, and still lose 1 to 5%; `trash` stays fast instead
  ([proofs/put-back](proofs/put-back/README.md), its DECISIONS.md).
- Finder writes the file lazily, a minute or two after a move. An item
  Finder trashed moments ago can show "origin unknown" until then.
- Records are never removed when items leave the Trash. One whose name a
  later item reuses can name the earlier item's folder, when the later one
  got no record of its own.

So `trash` keeps its own record too: every item it moves is stamped with its
original path and the time, an xattr on the item itself
(`com.adriangalilea.trash.origin`) that no other process can erase. An item
with either record goes back where it says. Where both exist and name
different places, the stamp written when the item arrived wins: macOS's
record can be a stale one of an earlier item of the same name. A stamp from
an earlier move (Finder's Put Back carries it out with the item, and
something else trashed it again) is set aside for macOS's record.

## It empties what Finder can't

macOS hides AppleDouble `._` metadata files in the Trash from Finder and
from every app built on Foundation's directory listing. A Trash can hold
thousands of them - typically left behind after deleting folders that once
lived on exFAT/FAT drives - while Finder shows it empty and greys out
Empty Trash, keeping the bytes on disk indefinitely. `trash --list` reports
them, `trash --empty` deletes them with everything else, and the
confirmation states both counts. Check yours: `ls -A ~/.Trash` next to an
"empty" Trash can be a surprise.

## Install

```sh
brew install --cask adriangalilea/tap/trash
```

That installs `trash.app` and links the `trash` command from inside it.
Installed as the old Homebrew formula? `brew uninstall trash` first.

Homebrew quarantines what a cask downloads, and macOS shows a quarantined
app's first launch a Gatekeeper prompt. Launched with nobody at the screen
(over ssh, from a script), that launch waits for the prompt's answer before
any of trash's own code runs. Open `trash.app` once, or run `trash` once at
the screen, before relying on it unattended; `timeout 10 trash --check` says
whether anything would wait.

## Nothing waits on a person who is not there

With nobody at the unlocked screen, `--list`, `--restore` and `--empty` never open
trash.app's grant window: they fail at once saying what is missing. A
relaunch as trash.app that macOS holds fails within 10 seconds, naming what
to look at, and `--empty` with nobody to answer its question does nothing.

## Reading the Trash needs Full Disk Access

Moving things into the Trash works from anywhere. Reading it (`--list`,
`--restore`, `--empty`) doesn't: macOS lets only a process with Full Disk Access
read `~/.Trash`, grants it to the app a command runs in (your terminal), never
to the command, and never asks. Without it, `trash --list` says so and exits 1;
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

- Every word is a file, whatever it is named: `trash list empty` trashes two
  files. The other actions are flags, so a file name can never be read as
  one. A file whose name starts with `-` goes after `--`: `trash -- -x`.
- `/usr/bin/trash`'s flags work the same: `-v`/`--verbose` (what was trashed
  is always said) and `-s`/`--stopOnError`.
- `--restore` puts an item back where its records say. It never
  overwrites and creates no folder: if the original directory is gone, the
  item has no record, or an old stamp and the record disagree, it says so and takes a
  destination directory instead. It leaves `.DS_Store` as it is.
- Duplicate names don't happen: macOS renames on collision inside the Trash
  (`dup.txt` then `dup.txt 14-27-01-327.txt`), and each item restores to its
  true origin and name regardless of the trash-side rename. If a duplicate
  somehow appears anyway, `--restore` refuses rather than guesses.
- Home-volume Trash only. Items trashed on external volumes live in that
  volume's `.Trashes` and stay Finder's business.

## Requirements

macOS 27+. Built with SwiftPM; one dependency, swift-utils, for trash.app's
grant (`PermissionGrants`) and the command's description, help and skill
(`TerminalPrograms`). `TrashKit` is everything
done to the Trash (no printing, no exits), the `.DS_Store` reader included
(`Sources/TrashKit/DSStore.swift`); the `trash` target is the command's
words and the run-as-app hop (`Sources/trash/AsApp.swift`). `swift run putback` shows what is read for
each item in your Trash, and `swift run putback NAME=/expected/path NAME=-`
checks it against what you know.
