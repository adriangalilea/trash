# Decisions on where an item came from

Each decision: what was asked, the options, what was measured, what was
chosen and why, what would change it, and where the code of each option
lives. A decision found wrong is corrected here, with the evidence, never
silently. Measurements: README.md beside this file, and `prove.sh`.

## 1. Which record says where an item came from

**Asked:** can trash rely on macOS's own Put Back record alone (one source
of truth, the one Finder reads), instead of its own?

**Options:**
- A. macOS's record alone. trash stops writing its own.
- B. trash's own stamp alone, as trash 1.x did: an xattr on the item,
  `com.adriangalilea.trash.origin`, written by the process that moved it.
- C. Both: trash writes its stamp, and reads macOS's record too, so it knows
  where Finder's and other tools' items came from.

**Measured (2026-11-24, macOS 27.0.1):** macOS's record is lost for every
item after the first a process moves (README.md, Results), a bug public
since 2015. Even moving one item per process, 1 to 5% of items got no
record, the first item of a run included, and never got one later. The
likely cause, not proven: every trashing process rewrites the one
`~/.Trash/.DS_Store`, so moves at the same moment erase each other's
records (proving it needs `fs_usage`, which needs root). Finder writes its
records a minute or two late, but loses none. The stamp was never lost: it
is on the item, and no other process writes it.

**Chosen: C.** A alone would leave 1 to 5% of what trash moves with no
origin, worse than trash 1.x. B alone would know nothing of what Finder and
other tools trashed.

Which record wins, when both exist and name different places, is decided by
when the stamp was written. Either can be stale: macOS never removes a
record, so an item macOS gave no record (every item after the first of a
run) matches an old record of an earlier item of the same name; and the
stamp travels with the item, so an item Finder put back and something else
trashed again holds the stamp of the earlier move. The stamp holds the time
it was written, and the Trash holds when each item arrived: a stamp written
within a minute after the arrival records this move and wins; an older one
is set aside and macOS's record is used. A stamp with no time (trash 1.x)
that disagrees is shown beside the record and never guessed between.

*Corrected the same day.* The first version showed every disagreement and
asked for a destination. In real use that left trash unable to put back its
own items whenever their name had been trashed before (`notes.txt`, `tree`:
a stale record of an earlier item against the right stamp), which is
common. Fixed by recording when the stamp was written; the three cases (this
move against a stale record, a stale stamp against a fresh record, a 1.x
stamp) were proven on a clean Trash.

**Would change it:** macOS recording every item reliably (`prove.sh` would
say CHANGED), or a way to make the stamp travel correctly through Finder.

**Code:** C is what trash ships (ce3af1b). A, macOS's record alone, is the
tag `native-put-back` (51b6e07..bdf5e8c, with 75b9d42 the reader):
`git show native-put-back`, `git switch --detach native-put-back` to build it.

## 2. One process for every path, or one per path

**Asked:** should `trash a b c` move each path in a process of its own, so
macOS records each item and Finder's Put Back works on all of them?

**Measured (2026-11-24, release build, no Finder window):** one process per
path costs about 67 ms per path: 1 path 0.07 s warm, 10 paths 0.69 s, 100
paths 6.7 s. `/usr/bin/trash` moves 10 in 0.06 s. It recorded most items,
not all: 1 to 5% lost (decision 1). Waiting 2.5 s between items in one
process records all three in `prove.sh` (`api-two5`), at 2.5 s an item.

**Chosen: one process, speed.** trash's own restore is exact either way (decision 1). What it costs:
Finder's own Put Back works only for the first item of a multi-path
`trash` run, as with Apple's `/usr/bin/trash`.

**Would change it:** wanting Finder's Put Back for what trash moves badly
enough to pay 67 ms a path for 95 to 99% of items, or macOS fixing the bug.

**Code:** one process per path is commit 5a8400c, in the tag
`native-put-back`. trash reverts it (1bcaf84, whose message says why).

## 3. Writing `.DS_Store` ourselves

**Not done.** Writing the missing records would make Finder's Put Back work
for everything trash moves, at no cost per path. But `.DS_Store` is Finder's
private, undocumented format, rewritten by Finder while it runs: a second
writer risks corrupting the record of every item in the Trash, and the
evidence above suggests concurrent writers are what loses records today.
trash reads it by its structure (`DSStore.swift`) and never writes it.

**Would change it:** an Apple API to record Put Back, or proof that a write
can never race Finder's.

## Open

- **The loss's cause** is a likelihood, not a fact: confirm with `fs_usage`
  (root) while `prove.sh` runs alongside another trashing process.
- **`prove.sh open`** (Finder's Trash window open) has not been run under
  the watched proof; the readings by hand with the window open are in
  README.md.
- **A home folder on another volume:** the reader assumes `ptbL` is relative
  to `/`.
- **Reporting a lost record at move time:** trash could check, after a run,
  that macOS recorded what it moved and say which items Finder's Put Back
  will not offer. Not built.
