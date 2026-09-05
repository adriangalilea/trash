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

// Ground truth for what the Trash holds: readdir(2). Foundation's
// contentsOfDirectory COALESCES AppleDouble sidecars - "._x" is presented as
// metadata of "x", or omitted outright when no "x" exists - and Finder shares
// the blindness: a Trash holding only "._" files renders as empty and greys
// out Empty Trash, while the bytes stay on disk. Only the BSD layer tells
// the truth, so phantom = on disk per readdir, invisible per Foundation.
@MainActor func rawNames() -> [(name: String, isDir: Bool)] {
    guard let d = opendir(trashDir().path) else { return [] }
    defer { closedir(d) }
    var out: [(String, Bool)] = []
    while let e = readdir(d) {
        let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        out.append((name, Int32(e.pointee.d_type) == DT_DIR))
    }
    return out
}

@MainActor func phantoms() -> [(name: String, isDir: Bool)] {
    var visible = Set((try? fm.contentsOfDirectory(atPath: trashDir().path)) ?? [])
    visible.insert(".DS_Store")  // real, but Finder-owned - not a phantom
    return rawNames().filter { !visible.contains($0.name) }
}

func plural(_ n: Int, _ word: String) -> String {
    "\(n) \(word)\(n == 1 ? "" : "s")"
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
    let ghosts = phantoms()
    if all.isEmpty && ghosts.isEmpty {
        print("Trash is empty")
        return
    }
    if !all.isEmpty {
        let nameWidth = min(max(all.map { $0.name.count }.max() ?? 4, 4), 44)
        for e in all {
            let name =
                e.name.count > nameWidth ? String(e.name.prefix(nameWidth - 1)) + "…" : e.name
            let date =
                e.added.map { dateFmt.string(from: $0) } ?? String(repeating: " ", count: 16)
            let origin = e.origin.map(tilde) ?? "(origin unknown: trashed outside this tool)"
            print(
                "\(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(date)  \(origin)"
            )
        }
    }
    if !ghosts.isEmpty {
        let what = "\(plural(ghosts.count, "hidden \"._\" metadata file")) invisible to Finder"
        if all.isEmpty {
            print(
                "No restorable items, but \(what) remain on disk\n"
                    + "(Finder shows this Trash as empty and greys out Empty Trash).\n"
                    + "`trash empty` removes them.")
        } else {
            print("+ \(what) - `trash empty` removes them too")
        }
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
    let ghostCount = phantoms().count
    guard !all.isEmpty || ghostCount > 0 else {
        print("Trash is empty")
        return
    }
    if !force {
        var what = [String]()
        if !all.isEmpty { what.append(plural(all.count, "item")) }
        if ghostCount > 0 {
            what.append(
                "\(plural(ghostCount, "hidden \"._\" metadata file")) Finder cannot see")
        }
        print(
            "Empty the Trash? \(what.joined(separator: " + ")) will be PERMANENTLY deleted. [y/N] ",
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
    // Phantom sweep AFTER the visible pass and RE-SCANNED: removing "x" may
    // take its coalesced "._x" along, so the prompt's count is a ceiling.
    var ghostsRemoved = 0
    for g in phantoms() {
        let p = trashDir().appendingPathComponent(g.name).path
        let ok = g.isDir ? (try? fm.removeItem(atPath: p)) != nil : unlink(p) == 0
        if ok {
            ghostsRemoved += 1
        } else {
            warn("\(g.name): cannot remove")
            failed = true
        }
    }
    if failed { exit(1) }
    var did = [String]()
    if !all.isEmpty { did.append(plural(all.count, "item")) }
    if ghostsRemoved > 0 { did.append(plural(ghostsRemoved, "hidden metadata file")) }
    print("Trash emptied (\(did.joined(separator: " + ")))")
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
