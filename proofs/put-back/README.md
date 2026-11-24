# Put Back is lost for most items macOS's own API trashes

`trash` exists because of what this page proves. Finder's **Put Back** puts an
item in the Trash back where it came from. It works for everything Finder
itself moves to the Trash. For items moved by `FileManager.trashItem`, the API
every program and Apple's own `/usr/bin/trash` use, it works for the first
item a process moves and is lost for the rest. The bug has been public since
2015 and is unfixed in macOS 27.

`prove.sh` is the proof: run it, and it says whether this still holds on the
Mac it runs on.

```
proofs/put-back/prove.sh closed   # Finder shows no window on the Trash
proofs/put-back/prove.sh open     # Finder shows the Trash in a window
```

It needs Full Disk Access for the terminal and about four minutes, moves 18
small `pbproof-*` scratch files into your Trash and leaves them there. It
watches Finder and the Trash for the whole run, and a run during which a
window opened or closed, or the Trash was emptied, is void rather than judged.

## Where Put Back lives

Nothing on the trashed item says where it came from. Put Back reads two
records Finder keeps for each item, by its name in the Trash, in
`~/.Trash/.DS_Store` (Finder's private, undocumented file format):

- `ptbL`: the original folder, relative to the volume's root, with a trailing
  slash: `private/tmp/x/`, or as Finder writes it,
  `System/Volumes/Data/Users/<you>/folder/` (the same place as
  `/Users/<you>/folder/`, reached through the Data volume).
- `ptbN`: the original name. An item renamed in the Trash because the name was
  taken (`notes 17.12.03.txt`) keeps its original name here.

Records are never removed: the file keeps a record for every name ever
trashed, long after the item is gone. A record is keyed only by the name in
the Trash, so an item that got no record of its own can match an old record
of an earlier item of the same name.

## What is lost, and when

`prove.sh` moves three fresh files in each way below, then reads the store
twice: 10 seconds later, and 180 seconds later (Finder writes the store
lazily; one of Finder's own records appeared 90 seconds after the move).

| Case | How the three files are moved |
|---|---|
| `api-each` | `FileManager.trashItem`, one file per process, back to back |
| `api-one` | `FileManager.trashItem`, three calls in one process |
| `api-half` | the same, 0.5 s between calls |
| `api-two5` | the same, 2.5 s between calls |
| `apple-each` | `/usr/bin/trash`, one file per run |
| `apple-one` | `/usr/bin/trash` with three files in one run |

`probe.swift` is the API alone, nothing of trash's.

### Results

`Y` = a Put Back record, `.` = none, per file, at +180 s.

| Date | macOS | Finder's Trash window | api-each | api-one | api-half | api-two5 | apple-each | apple-one |
|---|---|---|---|---|---|---|---|---|
| 2026-11-24 | 27.0.1 (26A434) | closed | YYY | Y.. | Y.. | YYY | YYY | Y.. |

The same at +10 s as at +180 s in that run: with no Trash window open,
nothing arrived late. The `open` column is not run yet.

### Measured by hand before the proof existed (2026-11-24, macOS 27.0.1)

Kept because they led here, with what was not controlled:

- `trashItem` three times in one process: first only, with 0.5 s waits too.
  Apple's `/usr/bin/trash a b c`: first only. Our own trash given three paths:
  first only. Finder state not recorded (probably no window open).
- In Finder, the person confirmed: no Put Back on a file `/usr/bin/trash`
  moved second in a run, nor on one our trash moved second; Put Back present
  on a file moved alone.
- Finder itself, one file, several, a folder tree, a renamed duplicate: every
  item recorded, the last one 90 seconds late. A first reading taken right
  after the moves called that item lost; it was not, it was late.
- With Finder's Trash window open (recorded): one file per process five times
  back to back, 4 of 5 recorded; `/usr/bin/trash a b c`, 0 of 3, not even
  the first; `/usr/bin/trash` one file per run three times, 3 of 3. Read 5 to
  60 seconds after the moves, before the lazy writes were known, so these may
  be late rather than lost: the proof's `open` run decides.

## What others found

- 2015-05: reported against sindresorhus/trash, "Trash multiple files won't get
  `put back` options" ([sindresorhus/trash#24](https://github.com/sindresorhus/trash/issues/24)).
- 2015-10: narrowed to two back-to-back `trashItemAtURL` calls in one process:
  only the first gets Put Back ([sindresorhus/macos-trash#4](https://github.com/sindresorhus/macos-trash/issues/4)).
  In the same thread: traced to `~/.Trash/.DS_Store`; filed with Apple as
  rdar://23153124, never answered; a 2 s sleep between calls is the shortest
  that worked (1.9 s did not); kornelski (ImageOptim) found it also happened
  with one file per process in two processes, and that Put Back once worked
  for all files, so a regression. 2018: still present on 10.13 and 10.14, a
  duplicate radar filed.
- 2025-02: Apple Developer Forums, the same for `trashItem` and
  `NSWorkspace.recycle`, "known for at least 10 years"; Apple's DTS engineer
  reproduced it on macOS 15.2 only while Finder's Trash window was open, and
  suspects Finder and the file manager "bumping into each other" over
  `.DS_Store`; no workaround offered
  ([thread 773997](https://developer.apple.com/forums/thread/773997)).
- 2026-10: an app switched to Finder's own recycle, spacing the requests,
  because the callback can arrive before Finder registers Put Back
  ([zubair-io/Maple#5340](https://github.com/zubair-io/Maple/pull/5340)).
- 2026-11: confirmed on macOS 26.6.2 with one `NSWorkspace.recycle` of three
  folders: Put Back for the first only
  ([jellydn/folderlens#30](https://github.com/jellydn/folderlens/pull/30)).

The workarounds in use: wait 2 s or more between items; have Finder do the
delete (AppleScript or ScriptingBridge, which needs a person's session and
Automation permission); or tell people to drag items back by hand.

## What trash does about it

Planned for trash 2.0, not in a release yet: trash 1.x moves every path
given in one process and records the origin only in its own extended
attribute (`com.adriangalilea.trash.origin`), which Finder does not read.

- **Moving:** every item in a process of its own, so macOS's record is
  written for each, without waiting between items and without Finder. Whether
  that holds with Finder's Trash window open is what the `open` run of this
  proof answers.
- **Reading:** `list` and `restore` read the records from `.DS_Store`, read
  only, so they know the origin of what Finder and other tools trashed too,
  and Finder's Put Back works on what trash trashed. A record for a name no
  longer in the Trash is ignored, and a missing record is "not recorded",
  never final, since Finder writes late.
- **Never writing `.DS_Store`:** Finder rewrites it while running, so writing
  it from outside could corrupt it.
