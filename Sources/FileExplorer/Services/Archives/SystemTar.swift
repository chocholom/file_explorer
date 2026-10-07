import Foundation

/// Wrapper around macOS's bsdtar (/usr/bin/tar, libarchive): lists and extracts
/// zip, tar, tgz, tbz2, txz, 7z, rar, iso and more.
enum SystemTar {
    static let executable = URL(fileURLWithPath: "/usr/bin/tar")

    struct ToolError: LocalizedError {
        let tool: String
        let status: Int32
        let message: String

        var errorDescription: String? {
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(tool) failed (exit \(status))." : detail
        }
    }

    static func list(_ archive: URL) throws -> [ArchiveEntry] {
        let output = try run(executable, ["-tvf", archive.path])
        guard let text = String(data: output, encoding: .utf8) ?? String(data: output, encoding: .isoLatin1) else {
            return []
        }
        return text.split(separator: "\n").compactMap { parseListingLine(String($0)) }
    }

    /// Extracts the given entry paths (folders recursively) into `directory`,
    /// preserving their paths inside the archive.
    static func extract(_ paths: [String], from archive: URL, to directory: URL) throws {
        guard !paths.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try run(executable, ["-xf", archive.path, "-C", directory.path, "--no-same-owner", "--"] + paths)
    }

    /// Extracts the whole archive into `directory`.
    static func extractAll(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try run(executable, ["-xf", archive.path, "-C", directory.path, "--no-same-owner"])
    }

    // MARK: Listing parser

    // "-rw-r--r--  0 mirek  staff    1234 Jul  7 12:34 dir/file name.txt"
    // "drwxr-xr-x  0 501    0           0 Oct  6  2024 dir/"
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^([-dlbcpsh])[-rwxsStTl]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}:\d{2}|\d{4})\s(.*)$"#)

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter
    }()

    static func parseListingLine(_ line: String, now: Date = Date()) -> ArchiveEntry? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = lineRegex.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        let type = group(1)
        let size = Int64(group(2)) ?? 0
        var name = group(6)
        if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        if type == "h", let link = name.range(of: " link to ") { name = String(name[..<link.lowerBound]) }
        guard let path = ArchiveEntry.normalize(name) else { return nil }

        let calendar = Calendar.current
        var components = DateComponents()
        components.month = monthFormatter.date(from: group(3)).map { calendar.component(.month, from: $0) }
        components.day = Int(group(4))
        let clock = group(5)
        if clock.contains(":") {
            // Recent entry: no year printed. Use this year unless that lands in the future.
            let parts = clock.split(separator: ":")
            components.hour = Int(parts[0])
            components.minute = Int(parts[1])
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year! -= 1
            }
        } else {
            components.year = Int(clock)
        }
        let modified = calendar.date(from: components) ?? .distantPast
        return ArchiveEntry(path: path, isDirectory: type == "d", size: type == "d" ? 0 : size, modified: modified)
    }

    // MARK: Process helper

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a tool, returning stdout; throws with stderr on a non-zero exit.
    /// Both pipes are drained concurrently so neither can fill up and block the tool.
    static func run(_ tool: URL, _ arguments: [String], currentDirectory: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let errorBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            throw ToolError(
                tool: tool.lastPathComponent, status: process.terminationStatus,
                message: String(data: errorBox.data, encoding: .utf8) ?? "")
        }
        return output
    }
}
