import Foundation

var failures = 0
var passes = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("ok   " + label)
    } else {
        failures += 1
        print("FAIL " + label)
    }
}

@main struct Main {
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macro-file-rename-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let source = root.appendingPathComponent("basic_pitch_transcription.mid")
        let destination = root.appendingPathComponent("03_Song.mid")
        let bytes = Data([0x4d, 0x54, 0x68, 0x64, 0x01])
        try bytes.write(to: source)
        let renamed = FileRename.run(source.path, destination.lastPathComponent)
        check(renamed.0, "renames one file in place")
        check(!manager.fileExists(atPath: source.path) && (try? Data(contentsOf: destination)) == bytes,
              "verifies source removal and unchanged destination contents")

        let collisionSource = root.appendingPathComponent("second.mid")
        let collisionDestination = root.appendingPathComponent("existing.mid")
        try bytes.write(to: collisionSource)
        try Data([0x01]).write(to: collisionDestination)
        let collision = FileRename.run(collisionSource.path, collisionDestination.lastPathComponent)
        check(!collision.0 && manager.fileExists(atPath: collisionSource.path),
              "refuses an existing destination without moving the source")
        check((try? Data(contentsOf: collisionDestination)) == Data([0x01]),
              "leaves an existing destination untouched")

        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        check(!FileRename.run(directory.path, "renamed").0, "refuses to rename a directory")
        check(!FileRename.run(collisionSource.path, "second.pdf").0, "refuses to change the extension")
        check(!FileRename.run(collisionSource.path, "../outside.mid").0, "refuses a path instead of a filename")
        check(!FileRename.run("relative.mid", "renamed.mid").0, "refuses a relative source path")
        check(!FileRename.run(root.appendingPathComponent("missing.mid").path, "renamed.mid").0,
              "reports a missing source file")

        print(failures == 0 ? "\n\(passes) file-rename checks passed" : "\n\(failures) FAILED, \(passes) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
