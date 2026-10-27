// Reading the Trash needs Full Disk Access, which macOS grants to the app a
// command runs in (the terminal), never to the command, and never asks for.
// So an operation is tried here first; only when macOS refuses it, and this
// binary sits inside trash.app, is it run again as trash.app: launched through
// LaunchServices, which makes trash.app its own app in macOS's eyes, holding
// its own grant. It does that one operation, writes the answer to a file and
// exits. One binary, one implementation (TrashKit), two places to run it.
import Foundation
import TrashKit

enum Request: Codable {
    case list
    case restore(name: String, into: String?)
    case empty
}

enum Reply: Codable {
    case listing(Listing)
    case restored(String)
    case emptied(Emptied)
    case failed(TrashError)
}

/// Where a reply came from: here, or trash.app at that path.
enum Runner {
    case here
    case app(URL)
}

func answer(_ request: Request) -> Reply {
    let trash = Trash()
    do throws(TrashError) {
        switch request {
        case .list: return .listing(try trash.list())
        case .restore(let name, let into): return .restored(try trash.restore(name, into: into))
        case .empty: return .emptied(try trash.empty())
        }
    } catch {
        return .failed(error)
    }
}

/// The operation, here when macOS lets this process read the Trash, else as
/// trash.app; when trash.app doesn't hold Full Disk Access yet, it asks for it
/// (its grant window) and the operation runs once more after. Every operation
/// reads the Trash before changing anything, so a refusal has done nothing yet.
func perform(_ request: Request) -> (Reply, Runner) {
    let here = answer(request)
    guard case .failed(.unreadable(EPERM)) = here, let app = AsApp.bundle else {
        return (here, .here)
    }
    let first = AsApp.run(request, app)
    guard case .failed(.unreadable(EPERM)) = first else { return (first, .app(app)) }
    note("trash.app is asking for Full Disk Access, once: its window is open. Waiting…")
    AsApp.askForGrant(app)
    return (AsApp.run(request, app), .app(app))
}

enum AsApp {
    static let serve = "--serve"
    static let grant = "--grant"

    /// The trash.app this binary is inside, through any symlink (Homebrew's
    /// bin link); nil for a bare build.
    static let bundle: URL? = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }()

    /// Runs `request` as trash.app and waits for its answer.
    static func run(_ request: Request, _ app: URL) -> Reply {
        let reply = FileManager.default.temporaryDirectory
            .appending(path: "trash-reply-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reply) }
        let json = String(decoding: try! JSONEncoder().encode(request), as: UTF8.self)
        // open's own words are kept, not shown: trash.app often finishes before
        // `open -W` starts waiting on it, which open reports ("Unable to block
        // on application") while the answer is already written. They matter
        // only when no answer came.
        let (status, said) = open(
            ["-W", "-n", "-g", "-j", app.path, "--args", serve, json, reply.path])
        guard let data = try? Data(contentsOf: reply) else {
            fail(
                "trash.app (\(app.path)) gave no answer (open exited \(status)"
                    + (said.isEmpty ? "" : ": \(said)") + ");"
                    + " its log: /usr/bin/log show --last 5m --predicate 'process == \"trash\"'")
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data) else {
            fail("trash.app answered something this trash cannot read: a different version?")
        }
        return decoded
    }

    /// trash.app's side: the request from argv, the answer to the file named.
    static func answerAndExit(_ arguments: [String]) -> Never {
        guard arguments.count == 2,
            let request = try? JSONDecoder().decode(Request.self, from: Data(arguments[0].utf8))
        else { fail("\(serve) wants <request json> <reply path>") }
        let data = try! JSONEncoder().encode(answer(request))
        do {
            try data.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
        } catch {
            fail("cannot write the answer to \(arguments[1]): \(error.localizedDescription)")
        }
        exit(0)
    }

    /// trash.app's grant window (GrantWindow), waited for: it closes itself
    /// the moment the grant is on, or when the person closes it. Never a new
    /// instance (no -n): a second command needing the grant meanwhile waits on
    /// the window already open instead of opening another.
    static func askForGrant(_ app: URL) {
        open(["-W", app.path, "--args", grant])
    }

    /// /usr/bin/open, its exit status and what it said on stderr.
    @discardableResult
    private static func open(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            fail("cannot run /usr/bin/open: \(error.localizedDescription)")
        }
        let said = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
