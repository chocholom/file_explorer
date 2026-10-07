import Foundation

/// Modifies ZIP archives in place with /usr/bin/zip: add staged files, delete entries,
/// create folders, rename. Other formats are read-only.
enum ArchiveWriter {
    static let zipExecutable = URL(fileURLWithPath: "/usr/bin/zip")

    struct ReadOnlyError: LocalizedError {
        let name: String
        var errorDescription: String? { "“\(name)” is read-only; only ZIP archives can be modified." }
    }

    static func ensureWritable(_ archive: URL) throws {
        guard ArchiveFormat.detect(archive)?.isWritable == true else {
            throw ReadOnlyError(name: archive.lastPathComponent)
        }
        guard FileManager.default.isWritableFile(atPath: archive.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: archive.path])
        }
    }

    /// Adds `relativePaths` (as laid out under `staging`) to the archive, recursively.
    /// Existing entries with the same names are updated.
    static func add(relativePaths: [String], stagedIn staging: URL, to archive: URL) throws {
        guard !relativePaths.isEmpty else { return }
        try ensureWritable(archive)
        _ = try SystemTar.run(
            zipExecutable, ["-r", "-y", "-q", archive.path, "--"] + relativePaths, currentDirectory: staging)
        ArchiveIndexCache.shared.invalidate(archive)
    }

    /// Deletes entries (folders with everything below them). Exact names, no wildcards.
    static func delete(_ paths: [String], from archive: URL, index: ArchiveIndex) throws {
        try ensureWritable(archive)
        var names: [String] = []
        for path in paths {
            guard let entry = index.entry(at: path) else { continue }
            if entry.isDirectory {
                names.append(path + "/")
                names.append(contentsOf: index.descendants(of: path).map { $0.isDirectory ? $0.path + "/" : $0.path })
            }
            names.append(path)
        }
        guard !names.isEmpty else { return }
        // zip -d exits 12 ("nothing to do") when none of the names exist — fine for us.
        do {
            _ = try SystemTar.run(zipExecutable, ["-d", "-q", "-nw", archive.path, "--"] + names)
        } catch let error as SystemTar.ToolError where error.status == 12 {
            // nothing matched
        }
        ArchiveIndexCache.shared.invalidate(archive)
    }

    static func createDirectory(_ path: String, in archive: URL) throws {
        try ensureWritable(archive)
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent(path), withIntermediateDirectories: true)
        _ = try SystemTar.run(zipExecutable, ["-q", archive.path, "--", path + "/"], currentDirectory: staging)
        ArchiveIndexCache.shared.invalidate(archive)
    }

    /// Rename = extract to staging, rename there, add under the new name, delete the old entry.
    static func rename(_ entry: ArchiveEntry, to newName: String, in archive: URL, index: ArchiveIndex) throws {
        try ensureWritable(archive)
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        try SystemTar.extract([entry.path], from: archive, to: staging)
        let parent = entry.parentPath
        let newPath = parent.isEmpty ? newName : "\(parent)/\(newName)"
        try FileManager.default.moveItem(
            at: staging.appendingPathComponent(entry.path), to: staging.appendingPathComponent(newPath))
        try add(relativePaths: [newPath], stagedIn: staging, to: archive)
        try delete([entry.path], from: archive, index: index)
    }

    static func makeStaging() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorer-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
