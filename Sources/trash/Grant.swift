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
        // One grant: its page (title, a line, the one button), then the
        // questions a person asks before giving a whole disk, answered; the
        // window sized to it all, gone the moment the switch is on.
        let page = NSHostingController(
            rootView: VStack(spacing: 28) {
                PermissionGrant.Page(.readTheTrash)
                Divider()
                Questions()
            }
            .padding(40).frame(width: 480))
        page.sizingOptions = [.preferredContentSize]
        PermissionGrant.readTheTrash.observe { standing in
            if standing.grade == .good { exit(0) }
        }
        let window = NSWindow(contentViewController: page)
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

    /// What anyone asked for Full Disk Access wants to know, in the window that
    /// asks: why the whole disk, what is done with it, and the way without it.
    private struct Questions: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                answer(
                    "Why the whole disk?",
                    "macOS has no permission for the Trash alone: reading it takes Full Disk Access, and macOS never asks for it on an app's behalf."
                )
                answer(
                    "What does trash.app do with it?",
                    "Lists, restores and empties the Trash when a trash command asks, then quits. Nothing else ever runs with it."
                )
                answer(
                    "Rather not?",
                    "Give Full Disk Access to your terminal instead. trash then reads the Trash itself and never opens this app; moving files into the Trash needs nothing at all."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func answer(_ question: String, _ text: String) -> some View {
            // The answer sits under its question, indented, so each pair reads
            // as one; the pairs stand further apart than their own lines.
            VStack(alignment: .leading, spacing: 8) {
                Text(question).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }

    private final class Closed: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { exit(1) }
    }
}
