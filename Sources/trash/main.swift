// trash: the macOS Trash from the command line, with a real Put Back. This
// file is the words: it reads the arguments, has TrashKit do the work (here,
// or as trash.app: AsApp.swift), and says what happened. Nothing is ever
// reported that didn't happen: an unreadable Trash is an error with its fix,
// never an empty Trash.
// Shadows /usr/bin/trash deliberately: identical base case (stdout empty,
// exit 0), superset otherwise. If this binary is missing, PATH falls through
// to Apple's and only the extras are lost.
import Foundation
import PermissionGrants
import TerminalPrograms
import TrashKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("trash: \(message)\n".utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("trash: \(message)\n".utf8))
}

/// stderr without the "trash: " prefix: breadcrumbs, not diagnostics.
func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

/// Every failure in words, with what to do about it.
func explain(_ error: TrashError, _ runner: Runner) -> String {
    switch error {
    case .unreadable(let code) where code == EPERM:
        let folder = tilde(Trash().folder.path)
        switch runner {
        case .app(let app):
            return "trash.app cannot read the Trash (\(folder)): it was not given Full Disk Access."
                + "\nopen \(tilde(app.path)) to give it, then run this again"
        case .here:
            return
                "cannot read the Trash (\(folder)): macOS lets only a process with Full Disk Access read it, and never asks."
                + "\ngive it to the app this runs in (System Settings › Privacy & Security › Full Disk Access),"
                + " or install trash.app, which holds it for every terminal: brew install --cask adriangalilea/tap/trash"
        }
    case .unreadable(let code):
        return "cannot read the Trash: \(String(cString: strerror(code)))"
    case .noSuchFile(let path):
        return "no such file: \(path)"
    case .notTrashed(let path, let why):
        return "\(path): \(why)"
    case .originNotRecorded(let path, let name, let code):
        return "trashed \(tilde(path)) as '\(name)', but its origin could not be stamped"
            + " (\(String(cString: strerror(code)))): if macOS recorded it, Finder's Put Back works;"
            + " else restore it with a destination, trash restore '\(name)' <dir>"
    case .putBackUnreadable(let why):
        return
            "cannot read the Trash's Put Back records (\(tilde(Trash().folder.path))/.DS_Store): \(why)"
            + "\nif Finder was writing it, run this again"
    case .notInTrash(let name, let similar):
        return "not in Trash: \(name)"
            + (similar.isEmpty ? "" : "\ndid you mean: " + similar.joined(separator: ", "))
    case .ambiguous(let name, let matches):
        return "\(matches.count) items named '\(name)' in Trash:\n"
            + matches.map {
                "  \($0.added.map(stamp.string) ?? "?")  \(describe($0.origin))"
            }.joined(separator: "\n")
            + "\nrestore via Finder, or empty the duplicates first"
    case .notADirectory(let path):
        return "destination is not a directory: \(path)"
    case .noOrigin(let name):
        return "macOS has no Put Back record for '\(name)'"
            + " (if Finder trashed it moments ago, it writes one within a couple of minutes)"
            + "\npass a destination: trash restore '\(name)' <dir>"
    case .originsDisagree(let name, let putBack, let stamp):
        return
            "'\(name)' has two origins: macOS's Put Back says \(tilde(putBack)), trash's stamp says \(tilde(stamp))"
            + "\npass the destination you want: trash restore '\(name)' <dir>"
    case .originFolderGone(let folder):
        return
            "original directory no longer exists: \(tilde(folder))\npass a destination: trash restore <name> <dir>"
    case .wouldOverwrite(let path):
        return "refusing to overwrite: \(tilde(path))"
    case .notRestored(let name, let why):
        return "\(name): restore failed: \(why)"
    }
}

// MARK: - commands

func put(_ paths: [String], stopOnError: Bool) {
    var failed = false
    for path in paths {
        if failed && stopOnError { exit(1) }
        do throws(TrashError) {
            let trashed = try Trash().put(path)
            // The undo breadcrumb on STDERR: stdout stays empty exactly like
            // /usr/bin/trash, so pipes never see a difference, while terminals
            // and transcripts keep the log. A collision rename is said, or
            // restore becomes a guessing game.
            note(
                "trashed: \(tilde(trashed.origin))"
                    + (trashed.renamed.map { " (in Trash as '\($0)')" } ?? ""))
        } catch {
            warn(explain(error, .here))
            failed = true
        }
    }
    if failed { exit(1) }
}

/// An origin in words, for list and for a refusal that lists items.
func describe(_ origin: Origin) -> String {
    switch origin {
    case .known(let path): tilde(path)
    case .disputed(let putBack, let stamp):
        "(origins disagree: Put Back says \(tilde(putBack)), trash's stamp says \(tilde(stamp)))"
    case .unknown: "(origin unknown: not recorded, or not yet if Finder trashed it moments ago)"
    }
}

func listing() -> (Listing, Runner) {
    let (reply, runner) = perform(.list)
    switch reply {
    case .listing(let listing): return (listing, runner)
    case .failed(let error): fail(explain(error, runner))
    default: fail("trash.app answered a list with something else")
    }
}

func list(json: Bool) {
    let (contents, _) = listing()
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try! encoder.encode(contents), as: UTF8.self))
        return
    }
    if contents.isEmpty {
        print("Trash is empty")
        return
    }
    let width = min(max(contents.items.map(\.name.count).max() ?? 4, 4), 44)
    for item in contents.items {
        let name = item.name.count > width ? String(item.name.prefix(width - 1)) + "…" : item.name
        let added = item.added.map(stamp.string) ?? String(repeating: " ", count: 16)
        print(
            "\(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(added)  \(describe(item.origin))"
        )
    }
    guard !contents.hidden.isEmpty else { return }
    let what = "\(plural(contents.hidden.count, "hidden \"._\" metadata file")) invisible to Finder"
    if contents.items.isEmpty {
        print(
            "No restorable items, but \(what) remain on disk\n"
                + "(Finder shows this Trash as empty and greys out Empty Trash).\n"
                + "`trash empty` removes them.")
    } else {
        print("+ \(what) - `trash empty` removes them too")
    }
}

func restore(_ name: String, into: String?) {
    let (reply, runner) = perform(.restore(name: name, into: into))
    switch reply {
    case .restored(let path): print("restored: \(tilde(path))")
    case .failed(let error): fail(explain(error, runner))
    default: fail("trash.app answered a restore with something else")
    }
}

func empty(force: Bool) {
    let (contents, _) = listing()
    guard !contents.isEmpty else {
        print("Trash is empty")
        return
    }
    if !force {
        var what: [String] = []
        if !contents.items.isEmpty { what.append(plural(contents.items.count, "item")) }
        if !contents.hidden.isEmpty {
            what.append(
                "\(plural(contents.hidden.count, "hidden \"._\" metadata file")) Finder cannot see")
        }
        print(
            "Empty the Trash? \(what.joined(separator: " + ")) will be PERMANENTLY deleted. [y/N] ",
            terminator: "")
        guard readLine()?.lowercased() == "y" else {
            print("Cancelled")
            exit(1)
        }
    }
    let (reply, runner) = perform(.empty)
    switch reply {
    case .emptied(let emptied):
        emptied.failed.forEach(warn)
        var did: [String] = []
        if emptied.items > 0 { did.append(plural(emptied.items, "item")) }
        if emptied.hidden > 0 { did.append(plural(emptied.hidden, "hidden metadata file")) }
        print("Trash emptied (\(did.isEmpty ? "nothing" : did.joined(separator: " + ")))")
        if !emptied.failed.isEmpty { exit(1) }
    case .failed(let error): fail(explain(error, runner))
    default: fail("trash.app answered an empty with something else")
    }
}

// MARK: - the program

enum Verb: TerminalProgram.Commands {
    case put, list, restore, empty, check

    static let paths = TerminalProgram.Arg.rest("paths")
    static let verbose = TerminalProgram.Flag.on(
        "verbose", short: "v",
        says: "accepted as /usr/bin/trash takes it: what was trashed is always said")
    static let stopOnError = TerminalProgram.Flag.on(
        "stop-on-error", short: "s", says: "stop at the first path that cannot be trashed")
    static let name = TerminalProgram.Arg.needed("name")
    static let into = TerminalProgram.Arg.optional("dir")
    static let force = TerminalProgram.Flag.on("force", short: "f", says: "do not ask first")

    var command: TerminalProgram.Command {
        switch self {
        case .put:
            .init(
                "put", args: [Verb.paths], flags: [Verb.verbose, Verb.stopOnError],
                says: "move files and folders to the Trash, recording where each came from",
                more: """
                    `trash <paths>` is this command: the same call as /usr/bin/trash, with nothing on stdout and exit 0 when every path moved. Each move is said on stderr (`trashed: <path>`, and the name it took in the Trash when one there had it), the undo's breadcrumb. A path that cannot be trashed is said and the others still go, unless --stop-on-error; any failure exits 1. A file named like a command goes by its path or after `--`: `trash ./list`, `trash -- list`.
                    """,
                examples: ["trash notes.txt build/", "trash -s a b c"],
                risk: .covered)
        case .list:
            .init(
                "list", args: [],
                says: "what is in the Trash: name, when it was trashed, where from",
                more: """
                    Where each came from is macOS's Put Back record, the one Finder reads. An item trashed by a tool that moved several at once may have none, and Finder writes its records a minute or two after the move. Finder cannot see AppleDouble "._" files in the Trash, so a Trash it shows as empty can still hold thousands: list counts them, empty removes them.
                    """,
                examples: ["trash list", "trash ls --json"],
                json:
                    "the items (name, added, origin: where restore puts it, putBack and stamp: what each record says) and the hidden \"._\" files",
                aliases: ["ls"], risk: .read)
        case .restore:
            .init(
                "restore", args: [Verb.name, Verb.into],
                says: "put an item back where it came from, or into dir",
                more: """
                    It goes back where its records say: trash's own stamp for what trash moved, macOS's Put Back record (the one Finder's Put Back uses) for what Finder or another tool moved. An item with neither, or whose two records disagree, needs dir. Nothing is ever overwritten.
                    """,
                examples: ["trash restore notes.txt", "trash restore photo.jpg ~/Desktop"],
                risk: .covered)
        case .empty:
            .init(
                "empty", flags: [Verb.force],
                says:
                    "delete everything in the Trash for good, the files Finder cannot see included",
                more:
                    "It asks first, and with nobody to answer it does nothing; --force does not ask.",
                examples: ["trash empty"],
                risk: .init(
                    .covered,
                    when: [
                        .flag(
                            Verb.force, .machine,
                            why: "it deletes the Trash for good with nobody asked",
                            instead: "trash empty")
                    ]))
        case .check:
            .init(
                "check", says: "whether trash works on this Mac right now, with nobody needed",
                more: """
                    For a caller with nobody at the screen (a script, a daemon, ssh) to ask before relying on trash. It reads, never changes anything: whether trash.app is quarantined (a quarantined app's launch can wait on a Gatekeeper prompt only a person answers), whether this process or trash.app can read the Trash (list, restore and empty need it), and whether a person is at the unlocked screen. Exit 0: `trash <paths>` works and nothing waits on a person; 1: something would, each reason with its fix. A launch macOS holds never reaches trash's own code, so call it under a limit: `timeout 10 trash check`.
                    """,
                examples: ["timeout 10 trash check", "trash check --json"],
                json: "ok, and each fact: quarantined, reading (here, trash.app or none), person",
                risk: .read)
        }
    }
}

/// trash.app's version, from the bundle this binary is inside; nil for a bare
/// build, which has no release.
let version = AsApp.bundle.flatMap {
    Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String
}

let program = TerminalProgram.Program<Verb>(
    name: "trash", says: "the macOS Trash from the command line, with a real Put Back",
    about: [
        "Reading the Trash needs Full Disk Access: where the terminal lacks it, trash.app reads it with its own."
    ],
    version: version, default: .init(.put, claims: { _ in true }), json: true,
    skill: .init(
        useWhen: [
            "moving files or folders to the Trash instead of deleting them",
            "what is in the Trash and where each item came from",
            "putting a trashed item back where it was",
        ],
        never: [
            "rm a file someone may want back: trash it",
            "empty the Trash without the person's yes",
        ]),
    risks: .init())

// MARK: - dispatch

// A launch as the permissions' fresh probe answers and exits (swift-utils
// PermissionGrants), before anything else.
PermissionGrant.answerProbeIfAsked()

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == AsApp.serve { AsApp.answerAndExit(Array(arguments.dropFirst())) }
// Asked for its grant by the command, or opened as an app by a person
// (Finder, Spotlight: no arguments, launched by launchd): the grant window.
if arguments.first == AsApp.grant || (arguments.isEmpty && getppid() == 1 && AsApp.bundle != nil) {
    GrantWindow.run()
}

// /usr/bin/trash's call, read as it reads it: --stopOnError is a spelling no
// flag here has, and a leading `--` ends the options, so every word after it
// is a path (`trash -- list` trashes the file list), never a command.
// WORKAROUND, ours: TerminalPrograms reads a command name after a leading
// `--` even in a program with a default command, so `--` is routed to put
// here. Delete the `["put"]` rewrite when swift-utils gives those words to
// the default command (its TODO.md, "`--` and the default command").
let call = program.read(
    (arguments.first == "--" ? ["put"] + arguments : arguments)
        .map { $0 == "--stopOnError" ? "--stop-on-error" : $0 })
switch call.command {
case .put: put(call[Verb.paths], stopOnError: call[Verb.stopOnError])
case .list: list(json: call.json)
case .restore: restore(call[Verb.name], into: call[Verb.into])
case .empty: empty(force: call[Verb.force])
case .check: check(json: call.json)
}
