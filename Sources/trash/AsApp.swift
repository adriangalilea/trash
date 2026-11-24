// Reading the Trash needs Full Disk Access, which macOS grants to the app a
// command runs in (the terminal), never to the command, and never asks for.
// So an operation is tried here first; only when macOS refuses it, and this
// binary sits inside trash.app, is it run again as trash.app: launched through
// LaunchServices, which makes trash.app its own app in macOS's eyes, holding
// its own grant. It does that one operation, writes the answer to a file and
// exits. One binary, one implementation (TrashKit), two places to run it.
// Nothing here waits on a person who is not there: the grant window needs
// someone at the unlocked screen, and a launch macOS holds (a Gatekeeper
// prompt nobody can answer) is an error within seconds, never a silent wait.
import Foundation
import IOKit
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
    if let absent = Person.absence() {
        fail(
            "trash.app has no Full Disk Access yet, and only a person can give it: \(absent)."
                + "\nat this Mac, open \(tilde(app.path)) and turn it on, then run this again")
    }
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

    /// How long trash.app has to start running once launched. Its start is
    /// a launch and a signature check, well under a second; past this, macOS
    /// is holding the launch, typically on a Gatekeeper prompt.
    static let startLimit: TimeInterval = 10

    /// Runs `request` as trash.app and waits for its answer: without limit
    /// once trash.app runs (emptying a large Trash takes what it takes),
    /// `startLimit` for it to start.
    static func run(_ request: Request, _ app: URL) -> Reply {
        let reply = FileManager.default.temporaryDirectory
            .appending(path: "trash-reply-\(UUID().uuidString).json")
        let started = startedMark(reply.path)
        defer {
            try? FileManager.default.removeItem(at: reply)
            try? FileManager.default.removeItem(at: started)
        }
        let json = String(decoding: try! JSONEncoder().encode(request), as: UTF8.self)
        // open's own words are kept, not shown: trash.app often finishes before
        // `open -W` starts waiting on it, which open reports ("Unable to block
        // on application") while the answer is already written. They matter
        // only when no answer came.
        let (status, said) = open(
            ["-W", "-n", "-g", "-j", app.path, "--args", serve, json, reply.path],
            startedWhen: started, within: startLimit,
            orFail:
                "trash.app (\(app.path)) did not start within \(Int(startLimit)) s: macOS is holding its launch."
                + (Person.absence().map { " Nobody can answer a prompt: \($0)." } ?? "")
                + "\nsee why: /usr/bin/log show --last 2m --predicate 'process == \"syspolicyd\"'")
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
        guard FileManager.default.createFile(atPath: startedMark(arguments[1]).path, contents: nil)
        else { fail("cannot write beside \(arguments[1])") }
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

    /// The file trash.app makes beside the reply the moment it runs.
    static func startedMark(_ replyPath: String) -> URL {
        URL(fileURLWithPath: replyPath + ".started")
    }

    /// /usr/bin/open, its exit status and what it said on stderr. With
    /// `startedWhen`, the opened app must make that file within `within`
    /// seconds, or open is stopped and the command fails with `orFail`.
    @discardableResult
    private static func open(
        _ arguments: [String], startedWhen mark: URL? = nil, within limit: TimeInterval = 0,
        orFail message: String = ""
    ) -> (Int32, String) {
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
        if let mark {
            let deadline = Date().addingTimeInterval(limit)
            while !FileManager.default.fileExists(atPath: mark.path) && process.isRunning {
                guard Date() < deadline else {
                    process.terminate()
                    fail(message)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let said = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Whether a person can answer this Mac right now: logged in at its screen,
/// on the console, unlocked. Read from the IORegistry's console users, which
/// a process reads the same from a terminal, an ssh session or launchd.
enum Person {
    /// Why nobody can answer, or nil when someone can.
    static func absence() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard
            let users = IORegistryEntryCreateCFProperty(
                root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
        else { return "nobody is logged in at this Mac's screen" }
        let uid = Int(getuid())
        guard let mine = users.first(where: { $0["kCGSSessionUserIDKey"] as? Int == uid }) else {
            return "this user is not logged in at this Mac's screen"
        }
        if mine["kCGSSessionOnConsoleKey"] as? Bool != true {
            return "this user's session is not the one on screen"
        }
        if mine["CGSSessionScreenIsLocked"] as? Bool == true { return "the screen is locked" }
        return nil
    }
}
