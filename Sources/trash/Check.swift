// `trash --check`: whether trash works on this Mac now, for a caller with
// nobody at the screen. It reads and changes nothing.
import Foundation
import TrashKit

struct Health: Encodable {
    /// `trash <paths>` works and nothing waits on a person.
    let ok: Bool
    let app: String?
    let version: String?
    /// trash.app carries com.apple.quarantine: its launches can wait on a
    /// Gatekeeper prompt.
    let quarantined: Bool
    /// Who can read the Trash for list, restore and empty: "here", "trash.app"
    /// or "none".
    let reading: String
    /// Why nobody can answer this Mac, nil when someone can.
    let absent: String?
    let problems: [String]
}

func check(json: Bool) {
    let app = AsApp.bundle
    let quarantined =
        app.map { getxattr($0.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 } ?? false
    let absent = Person.absence()
    var problems: [String] = []
    if quarantined, let app {
        problems.append(
            "\(tilde(app.path)) is quarantined: a launch can wait on a Gatekeeper prompt only a person answers."
                + " install it with no quarantine (hq ship install trash), or: xattr -d com.apple.quarantine \(app.path)"
        )
    }
    let reading: String
    if case .listing = answer(.list) {
        reading = "here"
    } else if let app, case .listing = AsApp.run(.list, app) {
        reading = "trash.app"
    } else {
        reading = "none"
        problems.append(
            "nothing here can read the Trash: list, restore and empty fail until trash.app has Full Disk Access"
                + (absent == nil
                    ? " (trash --list asks for it)" : ", which only a person at this Mac can give"))
    }
    let health = Health(
        ok: !quarantined, app: app?.path, version: version, quarantined: quarantined,
        reading: reading, absent: absent, problems: problems)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! encoder.encode(health), as: UTF8.self))
    } else {
        print(
            "trash.app     \(app.map { tilde($0.path) } ?? "none: a bare build")\(version.map { " \($0)" } ?? "")"
        )
        print("quarantined   \(quarantined ? "yes" : "no")")
        print("moving        FileManager.trashItem, needs nobody")
        print("reading       \(reading)")
        print("person        \(absent.map { "none: \($0)" } ?? "at the unlocked screen")")
        for problem in problems { warn(problem) }
    }
    exit(health.ok ? 0 : 1)
}
