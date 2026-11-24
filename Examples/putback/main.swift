// putback: what trash reads as each Trash item's origin, against a truth you
// state. Read-only: it lists the Trash (Full Disk Access needed) and never
// changes it.
//
//   swift run putback                         every item: Put Back, stamp, origin
//   swift run putback NAME=/abs/path NAME=-   only those, each checked: a path is
//                                             the expected Put Back origin, - none
//
// Exit 0 when every stated truth matches, 1 when one does not.
import Foundation
import TrashKit

let truths: [(name: String, expected: String?)] = CommandLine.arguments.dropFirst().map {
    let parts = $0.split(separator: "=", maxSplits: 1)
    precondition(parts.count == 2, "a truth is NAME=/abs/path or NAME=-: '\($0)'")
    return (String(parts[0]), parts[1] == "-" ? nil : String(parts[1]))
}

let listing: Listing
do {
    listing = try Trash().list()
} catch {
    FileHandle.standardError.write(Data("putback: \(error)\n".utf8))
    exit(1)
}
let items = Dictionary(listing.items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

func show(_ origin: Origin) -> String {
    switch origin {
    case .known(let path): "known \(path)"
    case .disputed(let putBack, let stamp): "DISPUTED put-back \(putBack) vs stamp \(stamp)"
    case .unknown: "unknown"
    }
}

if truths.isEmpty {
    for item in listing.items {
        print(
            "\(item.name)\n  put back: \(item.putBack ?? "-")\n  stamp: \(item.stamp ?? "-")\n  origin: \(show(item.origin))"
        )
    }
    exit(0)
}

var wrong = 0
for truth in truths {
    guard let item = items[truth.name] else {
        print("MISSING  \(truth.name): not in the Trash")
        wrong += 1
        continue
    }
    let ok = item.putBack == truth.expected
    if !ok { wrong += 1 }
    print(
        "\(ok ? "ok      " : "WRONG   ") \(truth.name)\n  expected: \(truth.expected ?? "-")\n  read:     \(item.putBack ?? "-")"
            + (item.stamp.map { "\n  stamp: \($0)" } ?? "")
            + "\n  origin:   \(show(item.origin))")
}
print("\(truths.count - wrong)/\(truths.count) as stated")
exit(wrong == 0 ? 0 : 1)
