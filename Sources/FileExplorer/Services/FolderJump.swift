import Foundation
import Observation

enum Fuzzy {
    /// Subsequence match with bonuses for word/path boundaries and consecutive
    /// runs, and a penalty for long candidates. Returns nil when `query` is not
    /// a subsequence of `candidate`. Both are expected lowercased.
    static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return nil }
        var queryIndex = query.startIndex
        var score = 0
        var streak = 0
        var previous: Character = "/"

        for character in candidate {
            if queryIndex < query.endIndex, character == query[queryIndex] {
                streak += 1
                let boundaryBonus = "/ -_.".contains(previous) ? 8 : 0
                score += 1 + streak * 2 + boundaryBonus
                queryIndex = query.index(after: queryIndex)
            } else {
                streak = 0
            }
            previous = character
        }

        guard queryIndex == query.endIndex else { return nil }
        return score - candidate.count / 4
    }
}

/// Indexes folders and files under the home directory for the "jump anywhere" panel.
@MainActor
@Observable
final class FolderJumpModel {
    static let shared = FolderJumpModel()

    struct Match: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        var id: URL { url }
    }

    var query = "" {
        didSet { updateMatches() }
    }
    private(set) var matches: [Match] = []
    var selectedIndex = 0
    private(set) var isBuilding = false

    private struct Entry {
        let path: String
        let isDirectory: Bool
    }

    private var indexed: [Entry] = []
    private var built = false
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    nonisolated private static let maxDepth = 5
    nonisolated private static let maxEntries = 100_000
    nonisolated private static let skippedNames: Set<String> = [
        "node_modules", ".git", ".build", "Caches",
    ]

    func prepare() {
        guard !built, !isBuilding else { return }
        isBuilding = true
        let root = home
        Task.detached(priority: .userInitiated) {
            let entries = Self.walk(root: root)
            await MainActor.run {
                self.indexed = entries
                self.built = true
                self.isBuilding = false
                self.updateMatches()
            }
        }
    }

    nonisolated private static func walk(root: URL) -> [Entry] {
        var entries: [Entry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return entries }

        for case let url as URL in enumerator {
            guard entries.count < maxEntries else { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isDirectory = values.isDirectory == true
            if isDirectory,
                values.isPackage == true || skippedNames.contains(url.lastPathComponent)
            {
                enumerator.skipDescendants()
                continue
            }
            entries.append(Entry(path: url.path, isDirectory: isDirectory))
            if isDirectory, enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
        }
        return entries
    }

    private func updateMatches() {
        // A typed path ("~/Dow", "/Volumes/") completes against the file system
        // instead of the fuzzy index, so any folder is reachable, indexed or not.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            matches = Self.pathCompletions(for: trimmed, home: home)
            selectedIndex = 0
            return
        }

        let normalized = query.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
        guard normalized.count >= 2 else {
            matches = []
            selectedIndex = 0
            return
        }

        let homePrefix = home.path
        var scored: [(score: Int, entry: Entry)] = []
        for entry in indexed {
            let relative =
                entry.path.hasPrefix(homePrefix)
                ? String(entry.path.dropFirst(homePrefix.count)).lowercased()
                : entry.path.lowercased()
            if let score = Fuzzy.score(query: normalized, candidate: relative) {
                // Folders get a slight edge over files on equal-quality matches.
                scored.append((entry.isDirectory ? score + 4 : score, entry))
            }
        }
        matches = scored
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { Match(url: URL(fileURLWithPath: $0.entry.path), isDirectory: $0.entry.isDirectory) }
        selectedIndex = 0
    }

    nonisolated private static func pathCompletions(for text: String, home: URL) -> [Match] {
        guard let typed = PathInput.resolve(text, relativeTo: home) else { return [] }
        var results: [Match] = []
        if FileSystemHelpers.isDirectory(typed) {
            results.append(Match(url: typed, isDirectory: true))
        }
        let endsWithSlash = text.hasSuffix("/")
        let parent = endsWithSlash ? typed : typed.deletingLastPathComponent()
        let prefix = endsWithSlash ? "" : typed.lastPathComponent.lowercased()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        let candidates = children
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix) }
            .filter { $0.standardizedFileURL.path != typed.path }
            .map { Match(url: $0.standardizedFileURL, isDirectory: FileSystemHelpers.isDirectory($0)) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        results.append(contentsOf: candidates.prefix(30))
        return results
    }

    /// "~/Downloads/Wallpapers" style label for the match list.
    func displayPath(for url: URL) -> String {
        let path = url.path
        if path.hasPrefix(home.path) {
            return "~" + path.dropFirst(home.path.count)
        }
        return path
    }
}
