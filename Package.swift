// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "trash",
    platforms: [.macOS(.v27)],
    dependencies: [
        // PermissionGrants: trash.app's Full Disk Access, read live and asked
        // for the studio's way.
        .package(
            url: "https://github.com/adriangalilea/swift-utils", .upToNextMinor(from: "0.109.0"))
    ],
    targets: [
        // Everything trash does to the Trash; no printing, no exits.
        .target(name: "TrashKit"),
        // The command: arguments, words, and running as trash.app when macOS
        // refuses this process the Trash (AsApp.swift), asking for its grant
        // when it has none (Grant.swift).
        .executableTarget(
            name: "trash",
            dependencies: [
                "TrashKit", .product(name: "PermissionGrants", package: "swift-utils"),
                .product(name: "TerminalPrograms", package: "swift-utils"),
            ]),
        // The proof of the Put Back reader against the live Trash, read-only:
        // `swift run putback NAME=/expected/origin ...`.
        .executableTarget(name: "putback", dependencies: ["TrashKit"], path: "Examples/putback"),
    ]
)
