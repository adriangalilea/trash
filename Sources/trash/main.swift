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
        return "trashed \(tilde(path)) as '\(name)', but its origin could not be recorded"
            + " (\(String(cString: strerror(code)))): restore it with a destination, trash restore '\(name)' <dir>"
    case .notInTrash(let name, let similar):
        return "not in Trash: \(name)"
            + (similar.isEmpty ? "" : "\ndid you mean: " + similar.joined(separator: ", "))
    case .ambiguous(let name, let matches):
        return "\(matches.count) items named '\(name)' in Trash:\n"
            + matches.map {
                "  \($0.added.map(stamp.string) ?? "?")  \($0.origin.map(tilde) ?? "(origin unknown)")"
            }.joined(separator: "\n")
            + "\nrestore via Finder, or empty the duplicates first"
    case .notADirectory(let path):
        return "destination is not a directory: \(path)"
    case .noOrigin(let name):
        return
            "no origin recorded for '\(name)' (trashed outside this tool)\npass a destination: trash restore '\(name)' <dir>"
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

func put(_ paths: [String]) {
    guard !paths.isEmpty else { fail("no paths given (see `trash help`)") }
    var failed = false
    for path in paths {
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

func listing() -> (Listing, Runner) {
    let (reply, runner) = perform(.list)
    switch reply {
    case .listing(let listing): return (listing, runner)
    case .failed(let error): fail(explain(error, runner))
    default: fail("trash.app answered a list with something else")
    }
}

func list() {
    let (contents, _) = listing()
    if contents.isEmpty {
        print("Trash is empty")
        return
    }
    let width = min(max(contents.items.map(\.name.count).max() ?? 4, 4), 44)
    for item in contents.items {
        let name = item.name.count > width ? String(item.name.prefix(width - 1)) + "…" : item.name
        let added = item.added.map(stamp.string) ?? String(repeating: " ", count: 16)
        let origin = item.origin.map(tilde) ?? "(origin unknown: trashed outside this tool)"
        print("\(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(added)  \(origin)")
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

func restore(_ arguments: [String]) {
    guard let name = arguments.first else {
        print("usage: trash restore <name> [destination-dir]\n")
        list()
        exit(1)
    }
    let (reply, runner) = perform(.restore(name: name, into: arguments.dropFirst().first))
    switch reply {
    case .restored(let path): print("restored: \(tilde(path))")
    case .failed(let error): fail(explain(error, runner))
    default: fail("trash.app answered a restore with something else")
    }
}

func empty(_ arguments: [String]) {
    let (contents, _) = listing()
    guard !contents.isEmpty else {
        print("Trash is empty")
        return
    }
    if !(arguments.contains("-f") || arguments.contains("--force")) {
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

func help() {
    print(
        """
        trash: macOS Trash CLI (native ~/.Trash, real Put Back)

        usage:
          trash <paths...>               move to Trash (records origin, prints breadcrumb)
          trash list (or: ls)            Trash contents: name, when, origin
          trash restore <name> [dir]     restore to origin (or into dir)
          trash empty [-f]               empty the Trash, invisible leftovers included (asks unless -f)

        A file literally named list/restore/empty/help: trash ./list  (or trash -- list)
        Items trashed by Finder or other tools have no recorded origin; restore
        them with an explicit destination, or with Finder's own Put Back.
        Finder cannot see AppleDouble "._" files in the Trash (an emptied-looking
        Trash can still hold thousands); list reports them, empty removes them.
        Reading the Trash needs Full Disk Access: where the terminal lacks it,
        trash.app (the cask) reads it with its own.
        """)
}

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
if arguments.isEmpty {
    help()
    exit(2)
}
switch arguments[0] {
case "help", "--help", "-h": help()
case "list", "ls": list()
case "restore": restore(Array(arguments.dropFirst()))
case "empty": empty(Array(arguments.dropFirst()))
// /usr/bin/trash compat: -v; breadcrumbs print regardless
case "--", "-v": put(Array(arguments.dropFirst()))
default:
    if arguments[0].hasPrefix("-") { fail("unknown option: \(arguments[0]) (see `trash help`)") }
    put(arguments)
}
