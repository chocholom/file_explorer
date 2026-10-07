import Foundation

/// Caches archive listings, keyed by path and validated against the file's size
/// and modification date so an archive changed on disk is re-read automatically.
/// Thread-safe: used from the main actor (listings) and the transfer worker.
final class ArchiveIndexCache: @unchecked Sendable {
    static let shared = ArchiveIndexCache()

    struct Stamp: Equatable {
        let size: Int64
        let modified: Date
    }

    private let lock = NSLock()
    private var indexes: [String: (index: ArchiveIndex, stamp: Stamp)] = [:]

    static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(
            size: (attributes[.size] as? Int64) ?? Int64((attributes[.size] as? Int) ?? 0),
            modified: (attributes[.modificationDate] as? Date) ?? .distantPast)
    }

    /// The index if it is cached and still matches the file on disk. Never blocks.
    func cached(for url: URL) -> ArchiveIndex? {
        guard let stamp = Self.stamp(of: url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = indexes[url.path], entry.stamp == stamp else { return nil }
        return entry.index
    }

    /// Returns the index, reading the archive if needed (blocking; call off the main thread).
    func index(for url: URL) throws -> ArchiveIndex {
        if let cached = cached(for: url) { return cached }
        guard let format = ArchiveFormat.detect(url) else { throw ZipReader.ZipError.notAZip }
        let stamp = Self.stamp(of: url)
        let rawEntries: [ArchiveEntry]
        switch format {
        case .zip:
            do {
                rawEntries = try ZipReader.entries(of: url)
            } catch {
                rawEntries = try SystemTar.list(url)  // self-extracting or odd ZIPs
            }
        case .libarchive:
            rawEntries = try SystemTar.list(url)
        }
        let index = ArchiveIndex(archiveURL: url, format: format, rawEntries: rawEntries)
        if let stamp {
            lock.lock()
            indexes[url.path] = (index, stamp)
            lock.unlock()
        }
        return index
    }

    func invalidate(_ url: URL) {
        lock.lock()
        indexes[url.path] = nil
        lock.unlock()
    }
}
