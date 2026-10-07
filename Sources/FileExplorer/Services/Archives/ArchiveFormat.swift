import Foundation

/// Archives the panes can browse like folders. ZIP is listed natively and can be
/// modified with /usr/bin/zip; everything else is read-only through bsdtar.
enum ArchiveFormat: Sendable {
    case zip
    case libarchive

    var isWritable: Bool { self == .zip }

    static func detect(_ url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if zipSuffixes.contains(where: { name.hasSuffix($0) }) { return .zip }
        if libarchiveSuffixes.contains(where: { name.hasSuffix($0) }) { return .libarchive }
        return nil
    }

    private static let zipSuffixes = [".zip", ".jar", ".ipa", ".cbz"]
    private static let libarchiveSuffixes = [
        ".tar", ".tgz", ".tar.gz", ".tbz", ".tbz2", ".tar.bz2", ".txz", ".tar.xz",
        ".tar.zst", ".tzst", ".7z", ".rar", ".cbr", ".iso", ".cpio",
    ]
}

/// A place inside an archive: the archive file plus a slash-separated entry path
/// ("" is the archive root). Shown in the UI as a virtual URL `archive.zip/inner/path`.
struct ArchivePath: Hashable, Sendable {
    let archiveURL: URL
    let path: String

    var format: ArchiveFormat { ArchiveFormat.detect(archiveURL) ?? .libarchive }
    var isRoot: Bool { path.isEmpty }
    var virtualURL: URL { path.isEmpty ? archiveURL : archiveURL.appendingPathComponent(path) }
    var name: String { path.isEmpty ? archiveURL.lastPathComponent : (path as NSString).lastPathComponent }

    func appending(_ component: String) -> ArchivePath {
        ArchivePath(archiveURL: archiveURL, path: path.isEmpty ? component : "\(path)/\(component)")
    }
}

enum ArchiveLocator {
    /// Non-nil when `url` is an archive file or a virtual path inside one. Walks up
    /// until a component exists on disk: a folder means "not an archive", a file with
    /// an archive extension means "inside it".
    static func locate(_ url: URL) -> ArchivePath? {
        var probe = url.standardizedFileURL
        var tail: [String] = []
        let fm = FileManager.default
        while probe.path != "/" {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: probe.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue, ArchiveFormat.detect(probe) != nil else { return nil }
                return ArchivePath(archiveURL: probe, path: tail.reversed().joined(separator: "/"))
            }
            tail.append(probe.lastPathComponent)
            probe = probe.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }
}

struct ArchiveEntry: Hashable, Sendable {
    /// Normalized: no leading "./" or "/", no trailing "/".
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var name: String { (path as NSString).lastPathComponent }
    /// "" for entries at the archive root.
    var parentPath: String { (path as NSString).deletingLastPathComponent }

    static func normalize(_ raw: String) -> String? {
        var path = raw
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        let components = path.split(separator: "/").filter { $0 != "." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}

/// Listing of one archive with implicit parent folders filled in (ZIPs often omit
/// directory entries) and a children map for instant folder listings.
struct ArchiveIndex: Sendable {
    let archiveURL: URL
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    private let childrenByParent: [String: [ArchiveEntry]]
    private let byPath: [String: ArchiveEntry]

    init(archiveURL: URL, format: ArchiveFormat, rawEntries: [ArchiveEntry]) {
        self.archiveURL = archiveURL
        self.format = format

        var byPath: [String: ArchiveEntry] = [:]
        for entry in rawEntries {
            if let existing = byPath[entry.path], existing.isDirectory, !entry.isDirectory { continue }
            byPath[entry.path] = entry
        }
        // Implicit parents inherit the newest child date.
        for entry in rawEntries {
            var parent = entry.parentPath
            while !parent.isEmpty {
                if let existing = byPath[parent] {
                    if existing.isDirectory, existing.modified < entry.modified, existing.size == 0,
                        rawEntries.first(where: { $0.path == parent }) == nil
                    {
                        byPath[parent] = ArchiveEntry(path: parent, isDirectory: true, size: 0, modified: entry.modified)
                    }
                } else {
                    byPath[parent] = ArchiveEntry(path: parent, isDirectory: true, size: 0, modified: entry.modified)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        let all = Array(byPath.values)
        entries = all
        self.byPath = byPath
        childrenByParent = Dictionary(grouping: all, by: \.parentPath)
    }

    func children(of path: String) -> [ArchiveEntry] {
        childrenByParent[path] ?? []
    }

    func entry(at path: String) -> ArchiveEntry? {
        byPath[path]
    }

    /// Everything below `path` (not including it), any depth.
    func descendants(of path: String) -> [ArchiveEntry] {
        let prefix = path + "/"
        return entries.filter { $0.path.hasPrefix(prefix) }
    }

    func exists(_ path: String) -> Bool {
        byPath[path] != nil
    }

    var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    var totalSize: Int64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }
}
