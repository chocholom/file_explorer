import Foundation

enum FileTypeCategory: String, CaseIterable, Identifiable, Hashable {
    case folders = "Folders"
    case images = "Images"
    case video = "Video"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives"
    case code = "Code"
    case apps = "Apps"
    case other = "Other"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .folders: return "folder"
        case .images: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .apps: return "app.badge"
        case .other: return "square.dashed"
        }
    }

    private static let extensionMap: [String: FileTypeCategory] = {
        var map: [String: FileTypeCategory] = [:]
        let groups: [(FileTypeCategory, [String])] = [
            (.images, ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif",
                       "bmp", "svg", "ico", "avif", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd"]),
            (.video, ["mp4", "mov", "mkv", "avi", "webm", "m4v", "mpg", "mpeg", "wmv", "flv", "ts"]),
            (.audio, ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus", "aiff", "aif", "mid", "midi"]),
            (.documents, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md",
                          "pages", "numbers", "key", "epub", "csv", "odt", "ods", "odp"]),
            (.archives, ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "dmg", "iso", "pkg"]),
            (.code, ["swift", "py", "js", "ts", "jsx", "tsx", "c", "cpp", "cc", "h", "hpp", "m", "mm",
                     "java", "kt", "rs", "go", "rb", "php", "sh", "zsh", "pl", "lua", "sql",
                     "json", "yaml", "yml", "toml", "xml", "html", "css", "scss"]),
            (.apps, ["app"]),
        ]
        for (category, exts) in groups {
            for ext in exts { map[ext] = category }
        }
        return map
    }()

    static func category(forExtension ext: String) -> FileTypeCategory {
        extensionMap[ext.lowercased()] ?? .other
    }
}
