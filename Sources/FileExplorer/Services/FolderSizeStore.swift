import Foundation
import Observation

/// Computes and caches recursive folder sizes off the main thread.
@MainActor
@Observable
final class FolderSizeStore {
    static let shared = FolderSizeStore()

    private(set) var sizes: [URL: Int64] = [:]
    @ObservationIgnored private var inFlight: Set<URL> = []

    func size(for url: URL) -> Int64? {
        sizes[url]
    }

    func request(_ url: URL) {
        guard sizes[url] == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            let total = Self.computeSize(of: url)
            await MainActor.run {
                self.sizes[url] = total
                self.inFlight.remove(url)
            }
        }
    }

    /// Drop cached sizes for a folder and its ancestors after a mutation inside it.
    func invalidate(under directory: URL) {
        let changed = directory.standardizedFileURL.path
        sizes = sizes.filter { entry in
            let cached = entry.key.standardizedFileURL.path
            return !Self.isSame(cached, orAncestorOrDescendantOf: changed)
        }
    }

    /// True when the paths are equal or one contains the other (component-wise, so
    /// "/a/foo" doesn't match "/a/foobar").
    nonisolated private static func isSame(_ a: String, orAncestorOrDescendantOf b: String) -> Bool {
        if a == b { return true }
        let aSlash = a.hasSuffix("/") ? a : a + "/"
        let bSlash = b.hasSuffix("/") ? b : b + "/"
        return a.hasPrefix(bSlash) || b.hasPrefix(aSlash)
    }

    nonisolated static func computeSize(of url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [])
        else { return 0 }
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
