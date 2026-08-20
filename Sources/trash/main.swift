// trash: macOS Trash CLI. Native ~/.Trash via FileManager.trashItem (the same
// API Finder uses), plus an xattr stamped on every trashed item recording its
// origin path, which is what makes `trash restore` a real Put Back.
// Shadows /usr/bin/trash deliberately: identical base case, superset otherwise.
// If this binary is missing, PATH falls through to Apple's and only the extras
// are lost.
import Foundation

let originXattr = "com.adriangalilea.trash.origin"
let fm = FileManager.default

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("trash: \(msg)\n".utf8))
    exit(1)
}

func warn(_ msg: String) {
    FileHandle.standardError.write(Data("trash: \(msg)\n".utf8))
}

// stderr without the "trash: " prefix: breadcrumbs, not diagnostics
func note(_ msg: String) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
}

@MainActor func trashDir() -> URL {
    fm.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
}

@MainActor func tilde(_ path: String) -> String {
    let home = fm.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func readOrigin(_ path: String) -> String? {
    let n = getxattr(path, originXattr, nil, 0, 0, XATTR_NOFOLLOW)
    guard n > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    let r = getxattr(path, originXattr, &buf, n, 0, XATTR_NOFOLLOW)
    guard r > 0 else { return nil }
    return String(bytes: buf[0..<r], encoding: .utf8)
}

struct Entry {
    let url: URL
    let name: String
    let added: Date?
    let origin: String?
}

// Home-volume Trash only; items trashed on other volumes land in that
// volume's .Trashes and are Finder's business.
@MainActor func entries() -> [Entry] {
    let urls =
        (try? fm.contentsOfDirectory(
            at: trashDir(), includingPropertiesForKeys: [.addedToDirectoryDateKey], options: []
        )) ?? []
    return
        urls
        .filter { $0.lastPathComponent != ".DS_Store" }
        .map { u in
            Entry(
                url: u,
                name: u.lastPathComponent,
                added: (try? u.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                    .addedToDirectoryDate,
                origin: readOrigin(u.path))
        }
        .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
}

let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

// MARK: - commands

@MainActor func cmdTrash(_ paths: [String]) {
    guard !paths.isEmpty else { die("no paths given (see `trash help`)") }
    var failed = false
    for p in paths {
        let url = URL(fileURLWithPath: p)
        // lstat, so a dangling symlink is still trashable
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else {
            warn("no such file: \(p)")
            failed = true
            continue
        }
        let origin = url.standardizedFileURL.path
        var landed: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &landed)
            // Undo breadcrumb on STDERR: stdout stays empty exactly like
            // /usr/bin/trash, so pipes and command substitution never see a
            // difference, while terminals and transcripts still get the log.
            var crumb = "trashed: \(tilde(origin))"
            if let landedURL = landed as URL? {
                origin.withCString {
                    _ = setxattr(landedURL.path, originXattr, $0, strlen($0), 0, XATTR_NOFOLLOW)
                }
                // A collision rename means the restore name is no longer what
                // was typed; say so, or restore becomes a guessing game.
                if landedURL.lastPathComponent != url.lastPathComponent {
                    crumb += " (in Trash as '\(landedURL.lastPathComponent)')"
                }
            }
            note(crumb)
        } catch {
            warn("\(p): \(error.localizedDescription)")
            failed = true
        }
    }
    if failed { exit(1) }
}

@MainActor func cmdList() {
    let all = entries()
    guard !all.isEmpty else {
        print("Trash is empty")
        return
    }
    let nameWidth = min(max(all.map { $0.name.count }.max() ?? 4, 4), 44)
    for e in all {
        let name =
            e.name.count > nameWidth ? String(e.name.prefix(nameWidth - 1)) + "…" : e.name
        let date = e.added.map { dateFmt.string(from: $0) } ?? String(repeating: " ", count: 16)
        let origin = e.origin.map(tilde) ?? "(origin unknown: trashed outside this tool)"
        print(
            "\(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(date)  \(origin)")
    }
}

@MainActor func cmdRestore(_ args: [String]) {
    guard let name = args.first else {
        print("usage: trash restore <name> [destination-dir]\n")
        cmdList()
        exit(1)
    }
    let matches = entries().filter { $0.name == name }
    switch matches.count {
    case 0:
        let near = entries().filter { $0.name.localizedCaseInsensitiveContains(name) }.prefix(5)
        var msg = "not in Trash: \(name)"
        if !near.isEmpty {
            msg += "\ndid you mean: " + near.map { $0.name }.joined(separator: ", ")
        }
        die(msg)
    case 1:
        break
    default:
        warn("\(matches.count) items named '\(name)' in Trash:")
        for m in matches {
            let d = m.added.map { dateFmt.string(from: $0) } ?? "?"
            warn("  \(d)  \(m.origin.map(tilde) ?? "(origin unknown)")")
        }
        die("ambiguous: restore via Finder, or empty the duplicates first")
    }
    let entry = matches[0]

    let target: URL
    if args.count > 1 {
        let destDir = URL(fileURLWithPath: args[1]).standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destDir.path, isDirectory: &isDir), isDir.boolValue else {
            die("destination is not a directory: \(args[1])")
        }
        target = destDir.appendingPathComponent(entry.name)
    } else if let origin = entry.origin {
        target = URL(fileURLWithPath: origin)
        var isDir: ObjCBool = false
        guard
            fm.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &isDir),
            isDir.boolValue
        else {
            die(
                "original directory no longer exists: \(tilde(target.deletingLastPathComponent().path))\n"
                    + "pass a destination: trash restore '\(name)' <dir>")
        }
    } else {
        die(
            "no origin recorded for '\(name)' (trashed outside this tool)\n"
                + "pass a destination: trash restore '\(name)' <dir>")
    }

    if (try? fm.attributesOfItem(atPath: target.path)) != nil {
        die("refusing to overwrite: \(tilde(target.path))")
    }
    do {
        try fm.moveItem(at: entry.url, to: target)
        _ = removexattr(target.path, originXattr, XATTR_NOFOLLOW)
        print("restored: \(tilde(target.path))")
    } catch {
        die("restore failed: \(error.localizedDescription)")
    }
}

@MainActor func cmdEmpty(_ args: [String]) {
    let force = args.contains("-f") || args.contains("--force")
    let all = entries()
    guard !all.isEmpty else {
        print("Trash is empty")
        return
    }
    if !force {
        let n = all.count
        print(
            "Empty the Trash? \(n) item\(n == 1 ? "" : "s") will be PERMANENTLY deleted. [y/N] ",
            terminator: "")
        guard let a = readLine(), a.lowercased() == "y" else {
            print("Cancelled")
            exit(1)
        }
    }
    var failed = false
    for e in all {
        do {
            try fm.removeItem(at: e.url)
        } catch {
            warn("\(e.name): \(error.localizedDescription)")
            failed = true
        }
    }
    if failed { exit(1) }
    print("Trash emptied (\(all.count) item\(all.count == 1 ? "" : "s"))")
}

func help() {
    print(
        """
        trash: macOS Trash CLI (native ~/.Trash, real Put Back)

        usage:
          trash <paths...>               move to Trash (records origin, prints breadcrumb)
          trash list                     Trash contents: name, when, origin
          trash restore <name> [dir]     restore to origin (or into dir)
          trash empty [-f]               empty the Trash (asks unless -f)

        A file literally named list/restore/empty/help: trash ./list  (or trash -- list)
        Items trashed by Finder or other tools have no recorded origin; restore
        them with an explicit destination, or with Finder's own Put Back.
        """)
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    help()
    exit(2)
}
switch args[0] {
case "help", "--help", "-h":
    help()
case "list", "ls":
    cmdList()
case "restore":
    cmdRestore(Array(args.dropFirst()))
case "empty":
    cmdEmpty(Array(args.dropFirst()))
case "--":
    cmdTrash(Array(args.dropFirst()))
case "-v":
    // /usr/bin/trash compat; breadcrumbs print regardless
    cmdTrash(Array(args.dropFirst()))
default:
    if args[0].hasPrefix("-") { die("unknown option: \(args[0]) (see `trash help`)") }
    cmdTrash(args)
}
