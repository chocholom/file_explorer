import Foundation
import Observation

/// User-added sidebar favorites (Total Commander's "directory hotlist"), persisted
/// as paths in UserDefaults. Built-in favorites (Home, Desktop, …) live in SidebarView.
@MainActor
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()
    private static let defaultsKey = "userFavorites"

    private(set) var urls: [URL]

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    func contains(_ url: URL) -> Bool {
        urls.contains { $0.path == url.standardizedFileURL.path }
    }

    func add(_ url: URL) {
        insert(url, at: urls.count)
    }

    /// Inserts at a position (sidebar drops land between existing favorites).
    /// Only folders are accepted; duplicates are ignored.
    func insert(_ url: URL, at index: Int) {
        let standardized = url.standardizedFileURL
        guard !contains(standardized), FileSystemHelpers.isDirectory(standardized) else { return }
        urls.insert(standardized, at: min(max(0, index), urls.count))
        save()
    }

    /// Adds every folder among the dropped URLs, starting at `index`.
    func insert(_ dropped: [URL], at index: Int) {
        var position = min(max(0, index), urls.count)
        for url in dropped {
            let before = urls.count
            insert(url, at: position)
            if urls.count > before { position += 1 }
        }
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    func toggle(_ url: URL) {
        contains(url) ? remove(url) : add(url)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        urls.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }
}
