import AppKit
import Observation

/// Tracks which pasteboard URLs came from a Cut, so Paste moves instead of copies.
/// Cut items render dimmed until pasted or the mark is replaced by a plain Copy.
@MainActor
@Observable
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var cutURLs: Set<URL> = []

    func markCut(_ urls: [URL]) {
        cutURLs = Set(urls)
    }

    func clearCut() {
        cutURLs = []
    }

    func isCut(_ url: URL) -> Bool {
        cutURLs.contains(url)
    }
}
