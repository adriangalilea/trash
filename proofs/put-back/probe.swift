// The macOS API alone, nothing of trash's: moves each path given with
// FileManager.trashItem, in this one process, `spacing` seconds apart.
//   probe <spacing-seconds> <path>...
// Prints each item's name in the Trash, one per line, so the proof can look
// up the record macOS wrote for exactly that name.
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let spacing = Double(arguments[0]) else {
    FileHandle.standardError.write(Data("usage: probe <spacing-seconds> <path>...\n".utf8))
    exit(64)
}
for (index, path) in arguments.dropFirst().enumerated() {
    if index > 0 && spacing > 0 { Thread.sleep(forTimeInterval: spacing) }
    var landed: NSURL?
    do {
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path), resultingItemURL: &landed)
    } catch {
        FileHandle.standardError.write(Data("probe: \(path): \(error)\n".utf8))
        exit(1)
    }
    guard let name = (landed as URL?)?.lastPathComponent else {
        FileHandle.standardError.write(Data("probe: \(path): macOS did not say where it went\n".utf8))
        exit(1)
    }
    print(name)
}
