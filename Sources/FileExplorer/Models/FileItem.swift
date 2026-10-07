import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isBrokenSymlink: Bool
    let size: Int64
    let modified: Date
    let ext: String
    let category: FileTypeCategory
    /// Folder-relative path shown for recursive-search results; nil in normal listings.
    var searchPath: String?
    /// Set for entries listed from inside an archive. `url` is then virtual
    /// (archive path + entry path) and doesn't exist on disk.
    let archiveEntry: ArchivePath?

    var id: URL { url }

    var isArchiveEntry: Bool { archiveEntry != nil }

    /// A real archive file the panes can enter like a folder (Return / double-click).
    var isArchive: Bool {
        archiveEntry == nil && !isDirectory && !isBrokenSymlink && ArchiveFormat.detect(url) != nil
    }

    /// Quick Look can render a real preview for these (used by hover preview & thumbnails).
    var isPreviewable: Bool {
        archiveEntry == nil && !isDirectory && (category == .images || category == .video || ext == "pdf")
    }

    init?(url: URL) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let isSymlink = values.isSymbolicLink ?? false
        // Packages (.app bundles etc.) behave like files: double-click opens them.
        var isDirectory = (values.isDirectory ?? false) && !(values.isPackage ?? false)
        var size = Int64(values.fileSize ?? 0)
        var isBroken = false

        if isSymlink {
            // Resource values describe the link itself; classify by the target instead,
            // so a symlinked folder navigates like a folder.
            let resolved = url.resolvingSymlinksInPath()
            var targetIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &targetIsDir) {
                let target = try? resolved.resourceValues(forKeys: [.isPackageKey, .fileSizeKey])
                isDirectory = targetIsDir.boolValue && !(target?.isPackage ?? false)
                if !targetIsDir.boolValue {
                    size = Int64(target?.fileSize ?? 0)
                }
            } else {
                isBroken = true
                isDirectory = false
            }
        }

        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isBrokenSymlink = isBroken
        self.size = size
        self.modified = values.contentModificationDate ?? .distantPast
        self.ext = url.pathExtension.lowercased()
        self.category = isDirectory ? .folders : FileTypeCategory.category(forExtension: ext)
        self.archiveEntry = nil
    }

    /// An entry inside an archive, addressed by a virtual URL.
    init(entry: ArchiveEntry, in archive: URL) {
        let location = ArchivePath(archiveURL: archive, path: entry.path)
        url = location.virtualURL
        name = entry.name
        isDirectory = entry.isDirectory
        isSymlink = false
        isBrokenSymlink = false
        size = entry.size
        modified = entry.modified
        ext = (entry.name as NSString).pathExtension.lowercased()
        category = entry.isDirectory ? .folders : FileTypeCategory.category(forExtension: ext)
        archiveEntry = location
    }

    var sizeText: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var dateText: String {
        modified == .distantPast ? "—" : Self.dateFormatter.string(from: modified)
    }

    var kindText: String {
        if isBrokenSymlink { return "Broken Link" }
        if isSymlink { return isDirectory ? "Link → Folder" : "Link" }
        if isDirectory { return "Folder" }
        if isArchive { return ext.isEmpty ? "Archive" : "\(ext.uppercased()) Archive" }
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
