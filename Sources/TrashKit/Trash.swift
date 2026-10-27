// The home volume's Trash (~/.Trash), the one implementation of everything
// trash does to it. No printing and no exits: every operation returns what
// happened or throws why it didn't, so the command line and trash.app (the
// same operations run with their own Full Disk Access) can never disagree.
//
// Moving into the Trash is FileManager.trashItem, the API Finder uses, plus an
// xattr on the trashed item recording where it came from: that xattr is what
// makes restore a real Put Back. Items trashed on other volumes land in that
// volume's .Trashes and stay Finder's business.
import Foundation

public let originXattr = "com.adriangalilea.trash.origin"

/// One item in the Trash, as Finder would show it.
public struct Item: Codable, Sendable {
    public let name: String
    public let added: Date?
    /// Where it was trashed from, when trash recorded it.
    public let origin: String?
}

/// An AppleDouble `._` file Foundation and Finder hide: on disk, never shown.
public struct Hidden: Codable, Sendable {
    public let name: String
    public let isDirectory: Bool
}

public struct Listing: Codable, Sendable {
    /// Newest first.
    public let items: [Item]
    public let hidden: [Hidden]
    public var isEmpty: Bool { items.isEmpty && hidden.isEmpty }
}

public struct Trashed: Codable, Sendable {
    public let origin: String
    /// The name it has in the Trash, when macOS renamed it on a collision.
    public let renamed: String?
}

public struct Emptied: Codable, Sendable {
    public let items: Int
    public let hidden: Int
    /// What could not be removed, each with why.
    public let failed: [String]
}

public enum TrashError: Error, Codable, Sendable {
    /// The Trash could not be listed (errno). EPERM: this process lacks Full
    /// Disk Access, which macOS requires to read ~/.Trash and never asks for.
    case unreadable(errno: Int32)
    case noSuchFile(String)
    case notTrashed(path: String, why: String)
    /// Trashed, but its origin could not be written: restore can't find home.
    case originNotRecorded(path: String, nameInTrash: String, errno: Int32)
    case notInTrash(name: String, similar: [String])
    case ambiguous(name: String, matches: [Item])
    case notADirectory(String)
    case noOrigin(name: String)
    case originFolderGone(String)
    case wouldOverwrite(String)
    case notRestored(name: String, why: String)
}

public struct Trash: Sendable {
    public let folder: URL

    public init() {
        folder =
            FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    }

    /// Moves `path` to the Trash and records where it came from.
    public func put(_ path: String) throws(TrashError) -> Trashed {
        let url = URL(fileURLWithPath: path)
        // lstat, so a dangling symlink is still trashable.
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw .noSuchFile(path) }
        let origin = url.standardizedFileURL.path
        var landed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        } catch {
            throw .notTrashed(path: path, why: error.localizedDescription)
        }
        guard let inTrash = landed as URL? else {
            throw .notTrashed(path: path, why: "macOS did not say where it went")
        }
        let written = origin.withCString {
            setxattr(inTrash.path, originXattr, $0, strlen($0), 0, XATTR_NOFOLLOW)
        }
        guard written == 0 else {
            throw .originNotRecorded(
                path: origin, nameInTrash: inTrash.lastPathComponent, errno: errno)
        }
        return Trashed(
            origin: origin,
            renamed: inTrash.lastPathComponent == url.lastPathComponent
                ? nil : inTrash.lastPathComponent)
    }

    public func list() throws(TrashError) -> Listing {
        let items = try visible()
        var shown = Set(items.map(\.name))
        shown.insert(".DS_Store")  // real, but Finder's own: not hidden clutter
        let hidden = try onDisk().filter { !shown.contains($0.name) }
        return Listing(items: items, hidden: hidden)
    }

    /// Puts `name` back where it was trashed from, or into `directory`. Never
    /// overwrites, never guesses between two items of one name.
    public func restore(_ name: String, into directory: String?) throws(TrashError) -> String {
        let items = try visible()
        let matches = items.filter { $0.name == name }
        guard matches.count < 2 else { throw .ambiguous(name: name, matches: matches) }
        guard let item = matches.first else {
            throw .notInTrash(
                name: name,
                similar: Array(
                    items.map(\.name).filter { $0.localizedCaseInsensitiveContains(name) }
                        .prefix(5)))
        }
        let target: URL
        if let directory {
            let folder = URL(fileURLWithPath: directory).standardizedFileURL
            guard isDirectory(folder.path) else { throw .notADirectory(directory) }
            target = folder.appending(path: item.name)
        } else {
            guard let origin = item.origin else { throw .noOrigin(name: name) }
            target = URL(fileURLWithPath: origin)
            let parent = target.deletingLastPathComponent().path
            guard isDirectory(parent) else { throw .originFolderGone(parent) }
        }
        var info = stat()
        guard lstat(target.path, &info) != 0 else { throw .wouldOverwrite(target.path) }
        do {
            try FileManager.default.moveItem(at: folder.appending(path: item.name), to: target)
        } catch {
            throw .notRestored(name: name, why: error.localizedDescription)
        }
        _ = removexattr(target.path, originXattr, XATTR_NOFOLLOW)
        return target.path
    }

    /// Deletes everything in the Trash for good, the files Finder can't see
    /// included.
    public func empty() throws(TrashError) -> Emptied {
        let items = try visible()
        var failed: [String] = []
        var removed = 0
        for item in items {
            do {
                try FileManager.default.removeItem(at: folder.appending(path: item.name))
                removed += 1
            } catch {
                failed.append("\(item.name): \(error.localizedDescription)")
            }
        }
        // After the items, read again: removing "x" can take its "._x" with it.
        var hidden = 0
        for file in try list().hidden {
            let path = folder.appending(path: file.name).path
            let gone =
                file.isDirectory
                ? (try? FileManager.default.removeItem(atPath: path)) != nil
                : unlink(path) == 0
            if gone { hidden += 1 } else { failed.append("\(file.name): cannot remove") }
        }
        return Emptied(items: removed, hidden: hidden, failed: failed)
    }

    /// What Finder shows. Foundation folds AppleDouble `._x` files into `x`
    /// (or drops them when no `x` exists), as Finder does.
    private func visible() throws(TrashError) -> [Item] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey])
        } catch {
            // Foundation's error wraps the POSIX one (257 over EPERM).
            let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw .unreadable(errno: Int32(posix?.code ?? Int(EPERM)))
        }
        return
            urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map {
                Item(
                    name: $0.lastPathComponent,
                    added: (try? $0.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                        .addedToDirectoryDate,
                    origin: origin(of: $0.path))
            }
            .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
    }

    /// What is on disk, readdir(2)'s truth: AppleDouble files included.
    private func onDisk() throws(TrashError) -> [Hidden] {
        guard let dir = opendir(folder.path) else { throw .unreadable(errno: errno) }
        defer { closedir(dir) }
        var found: [Hidden] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            found.append(Hidden(name: name, isDirectory: Int32(entry.pointee.d_type) == DT_DIR))
        }
        return found
    }

    private func origin(of path: String) -> String? {
        let size = getxattr(path, originXattr, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, originXattr, &bytes, size, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return String(bytes: bytes[..<read], encoding: .utf8)
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue
    }
}
