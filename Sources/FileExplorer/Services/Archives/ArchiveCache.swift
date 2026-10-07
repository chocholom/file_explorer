import CryptoKit
import Foundation

/// On-demand extraction of archive entries for Quick Look, Open, Get Info and
/// drag-out. Lives in ~/Library/Caches/<bundle id>/archives/<archive key>/<entry path>;
/// the key includes the archive's size and date, so a changed archive gets a fresh folder.
final class ArchiveCache: @unchecked Sendable {
    static let shared = ArchiveCache()

    let root: URL
    private let lock = NSLock()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "FileExplorer"
        root = caches.appendingPathComponent(bundle).appendingPathComponent("archives")
    }

    private func folder(for archive: URL) -> URL {
        let stamp = ArchiveIndexCache.stamp(of: archive)
        let key = "\(archive.path)|\(stamp?.size ?? 0)|\(stamp?.modified.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return root.appendingPathComponent(String(digest))
    }

    /// Where the entry lands once extracted (may not exist yet).
    func url(for entry: ArchivePath) -> URL {
        entry.isRoot ? folder(for: entry.archiveURL) : folder(for: entry.archiveURL).appendingPathComponent(entry.path)
    }

    /// The extracted file if it is already in the cache.
    func materialized(_ entry: ArchivePath) -> URL? {
        let url = url(for: entry)
        return FileSystemHelpers.exists(url) ? url : nil
    }

    /// Extracts the entry (a folder recursively) if needed and returns its real path.
    /// Blocking; call off the main thread for anything but tiny files.
    func materialize(_ entry: ArchivePath) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let existing = materialized(entry) { return existing }
        let destination = folder(for: entry.archiveURL)
        if entry.isRoot {
            try SystemTar.extractAll(entry.archiveURL, to: destination)
        } else {
            try SystemTar.extract([entry.path], from: entry.archiveURL, to: destination)
        }
        guard let result = materialized(entry) else {
            throw SystemTar.ToolError(tool: "tar", status: 0, message: "“\(entry.name)” wasn't found in the archive.")
        }
        return result
    }

    /// Synchronous extraction for drag & drop, capped so a drag start can't hang.
    func materializeIfSmall(_ entry: ArchivePath, size: Int64, limit: Int64 = 64_000_000) -> URL? {
        if let existing = materialized(entry) { return existing }
        guard size <= limit else { return nil }
        return try? materialize(entry)
    }

    /// Drops cache folders not touched for a while (called at launch).
    func purge(olderThanDays days: Int = 7) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: folder) }
        }
    }
}
