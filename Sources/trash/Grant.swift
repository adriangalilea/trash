// trash.app's one permission, a swift-utils PermissionGrant: read live from
// macOS on every use, asked through the library's own page. macOS has no prompt
// for Full Disk Access; asking opens its switch in System Settings, and the
// page moves on by itself the moment it is on.
import AppKit
import PermissionGrants
import SwiftUI

extension PermissionGrant {
    nonisolated static let readTheTrash = PermissionGrant.privacy(
        .fullDiskAccess, title: "Full Disk Access",
        why:
            "macOS lets only an app with it read the Trash. With it, trash lists, restores and empties the Trash from any terminal."
    )
}

enum GrantWindow {
    /// The grant's page in a window of trash.app's own, until the grant is on
    /// (exit 0) or the window is closed (exit 1). Already on: exits at once.
    @MainActor static func run() -> Never {
        if PermissionGrant.readTheTrash.isAllowed { exit(0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: PermissionGrant.Steps([.readTheTrash]) { exit(0) }
                    .padding(32)
                    .frame(width: 480)))
        window.title = "trash"
        window.styleMask.remove(.resizable)
        window.center()
        let closed = Closed()
        window.delegate = closed
        window.makeKeyAndOrderFront(nil)
        app.activate()
        withExtendedLifetime(closed) { app.run() }
        exit(1)
    }

    private final class Closed: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { exit(1) }
    }
}
