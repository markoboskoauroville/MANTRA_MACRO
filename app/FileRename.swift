import Foundation

enum FileRename {
    static func run(_ sourcePath: String, _ newName: String) -> (Bool, String) {
        let expanded = (sourcePath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return (false, "source must be an absolute path or start with ~/") }
        guard !newName.isEmpty,
              newName == (newName as NSString).lastPathComponent,
              newName != ".", newName != "..",
              !newName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return (false, "new name must be one filename, not a path")
        }

        let source = URL(fileURLWithPath: expanded).standardizedFileURL
        guard source.lastPathComponent != newName else { return (false, "source already has that name") }
        guard source.pathExtension.caseInsensitiveCompare((newName as NSString).pathExtension) == .orderedSame else {
            return (false, "new name must keep the original file extension")
        }

        let destination = source.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: false)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            return (false, "source file does not exist: " + source.path)
        }
        guard !isDirectory.boolValue else { return (false, "source is a directory, not a file") }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: source.path)
        } catch {
            return (false, "cannot inspect source file: " + error.localizedDescription)
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let originalSize = attributes[.size] as? NSNumber else {
            return (false, "source is not a regular file")
        }
        guard !manager.fileExists(atPath: destination.path) else {
            return (false, "destination already exists: " + destination.path)
        }

        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            return (false, "could not rename file: " + error.localizedDescription)
        }

        guard !manager.fileExists(atPath: source.path),
              let renamed = try? manager.attributesOfItem(atPath: destination.path),
              (renamed[.type] as? FileAttributeType) == .typeRegular,
              (renamed[.size] as? NSNumber)?.int64Value == originalSize.int64Value else {
            return (false, "rename was attempted but destination verification failed: " + destination.path)
        }
        return (true, "renamed \(source.path) to \(destination.path) (\(originalSize.int64Value) bytes; verified)")
    }
}
