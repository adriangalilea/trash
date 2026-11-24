// macOS's Put Back record, the one source of where a trashed item came from.
// Whoever moves an item into the Trash (Finder, FileManager.trashItem), macOS
// writes two records into the Trash's .DS_Store under the item's name THERE:
// `ptbL`, the folder it left, relative to the root and ending in "/"
// (`private/tmp/x/`, `System/Volumes/Data/Users/me/x/`), and `ptbN`, the name
// it had. Two facts shape every reading of them:
//
// - Finder writes .DS_Store lazily, a minute or more after the move: no record
//   means "not recorded", possibly "not yet", never "trashed elsewhere".
// - Records stay after their item leaves the Trash, so a record can be about
//   an earlier item of the same name. Only a process's FIRST trashItem is
//   recorded (a macOS bug), which is why trash moves each path in a process of
//   its own: every item it moves gets a fresh record over any stale one.
import Foundation

enum PutBack {
    /// The original path of each name in `names` that has a record.
    static func origins(in trash: URL, of names: Set<String>) throws(TrashError) -> [String: String]
    {
        guard let data = try store(in: trash) else { return [:] }
        let store: DSStore
        do {
            store = try DSStore(data)
        } catch {
            throw .putBackUnreadable(why: error.why)
        }
        var folders: [String: String] = [:]
        var originalNames: [String: String] = [:]
        for record in store.records where names.contains(record.name) {
            guard record.code == "ptbL" || record.code == "ptbN" else { continue }
            guard case .ustr(let text) = record.value else {
                throw .putBackUnreadable(
                    why: "'\(record.name)' has a \(record.code) that is not text")
            }
            if record.code == "ptbL" {
                folders[record.name] = text
            } else {
                originalNames[record.name] = text
            }
        }
        guard Set(folders.keys) == Set(originalNames.keys) else {
            let half = Set(folders.keys).symmetricDifference(originalNames.keys).sorted()
            throw .putBackUnreadable(
                why: "half a Put Back record (folder or name alone) for \(half)")
        }
        var origins: [String: String] = [:]
        for (name, folder) in folders {
            guard !folder.hasPrefix("/"), folder.isEmpty || folder.hasSuffix("/") else {
                throw .putBackUnreadable(
                    why: "'\(name)' has a folder that is not root-relative: '\(folder)'")
            }
            origins[name] = path(folder: folder, name: originalNames[name]!)
        }
        return origins
    }

    /// The .DS_Store's bytes, nil when there is none (nothing recorded yet).
    private static func store(in trash: URL) throws(TrashError) -> Data? {
        do {
            return try Data(contentsOf: trash.appending(path: ".DS_Store"))
        } catch {
            let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let code = Int32(posix?.code ?? 0)
            if code == ENOENT { return nil }
            throw .unreadable(errno: code == 0 ? EIO : code)
        }
    }

    /// The absolute path a person knows for a record's folder and name.
    /// `ptbL` is relative to the root. A folder of the Data volume reached
    /// through its mount point (`System/Volumes/Data/Users/...`, as Finder
    /// records it) is written as the firmlinked path it is the same place as
    /// (`/Users/...`), from macOS's own list of firmlinks.
    static func path(folder: String, name: String) -> String {
        precondition(!folder.hasPrefix("/") && (folder.isEmpty || folder.hasSuffix("/")))
        let absolute = "/" + folder + name
        let data = "/System/Volumes/Data/"
        guard absolute.hasPrefix(data) else { return absolute }
        let onData = String(absolute.dropFirst(data.count))
        guard
            let link = firmlinks.first(where: {
                onData == $0.onData || onData.hasPrefix($0.onData + "/")
            })
        else { return absolute }
        return link.path + onData.dropFirst(link.onData.count)
    }

    /// /usr/share/firmlinks: each line the path on the system volume, a tab,
    /// and the folder of the Data volume it leads to. Longest first, so the
    /// most specific link wins.
    static let firmlinks: [(path: String, onData: String)] = {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            preconditionFailure("macOS has no readable /usr/share/firmlinks")
        }
        return text.split(separator: "\n").map { line in
            let fields = line.split(separator: "\t")
            precondition(fields.count == 2, "a firmlinks line is not path<TAB>folder: '\(line)'")
            return (String(fields[0]), String(fields[1]))
        }.sorted { $0.onData.count > $1.onData.count }
    }()
}

/// trash 1.x's own origin record, an xattr holding the absolute path. It
/// exists for items trash 1.x moved, and goes when those are gone: nothing
/// writes it any more.
enum Trash1 {
    static let xattr = "com.adriangalilea.trash.origin"

    static func origin(of path: String) -> String? {
        let size = getxattr(path, xattr, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, xattr, &bytes, size, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return String(bytes: bytes[..<read], encoding: .utf8)
    }

    /// Takes the xattr off an item put back, so it never outlives the Trash.
    static func forget(at path: String) {
        _ = removexattr(path, xattr, XATTR_NOFOLLOW)
    }
}
