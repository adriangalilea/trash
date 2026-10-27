// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "trash",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything trash does to the Trash; no printing, no exits.
        .target(name: "TrashKit"),
        // The command: arguments, words, and running as trash.app when macOS
        // refuses this process the Trash (AsApp.swift).
        .executableTarget(name: "trash", dependencies: ["TrashKit"]),
    ]
)
