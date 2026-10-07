import Foundation

enum Archiver {
    /// Zips the given items (must share a parent directory) into `destination`.
    /// Uses /usr/bin/zip with paths relative to the parent so archives don't
    /// embed absolute paths; -y preserves symlinks as links.
    nonisolated static func compress(_ urls: [URL], into destination: URL) throws {
        guard let parent = urls.first?.deletingLastPathComponent() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = parent
        process.arguments = ["-r", "-y", "-q", destination.path, "--"] + urls.map(\.lastPathComponent)
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw ArchiveError.failed(message ?? "zip exited with \(process.terminationStatus)")
        }
    }

    enum ArchiveError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return "Compression failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
