import Foundation

/// Small, thread-safe file-system helpers shared by the view model and the
/// background transfer worker.
enum FileSystemHelpers {
    /// First free Finder-style name: "name.ext", "name copy.ext", "name copy 2.ext", …
    nonisolated static func uniqueDestination(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while exists(candidate) {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let newName = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    /// lstat-style existence check: true for broken symlinks too, which
    /// `fileExists(atPath:)` would miss and a later copy would trip over.
    nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// A real directory (not a symlink to one). Uses FileManager rather than
    /// `resourceValues`, which Foundation caches per URL instance: a long-lived URL
    /// (the pane's current folder) would keep reporting a deleted folder as present.
    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type != .typeSymbolicLink
    }

    nonisolated static func volumeID(of url: URL) -> String {
        let id = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        return id.map { "\($0)" } ?? url.path
    }

    /// Canonical path used for all "is this the same item / is this inside that"
    /// comparisons; resolves /var → /private/var and strips trailing slashes.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated static func freeSpace(at url: URL) -> Int64? {
        // Fresh URL instance: resource values are cached per instance (see isDirectory).
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
