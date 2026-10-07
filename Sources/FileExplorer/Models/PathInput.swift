import Foundation

/// Turns what a user types into a path field into a URL: `~` expansion, relative
/// paths (resolved against the current folder) and `file://` URLs.
enum PathInput {
    static func resolve(_ text: String, relativeTo base: URL) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }
        trimmed = (trimmed as NSString).expandingTildeInPath
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return base.appendingPathComponent(trimmed).standardizedFileURL
    }

    /// "~/Downloads" style display for paths inside the home folder.
    static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
