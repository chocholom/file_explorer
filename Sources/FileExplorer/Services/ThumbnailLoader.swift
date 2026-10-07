import AppKit
import QuickLookThumbnailing

/// Generates and caches Quick Look thumbnails for previewable files.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 2000
    }

    /// Returns a thumbnail for previewable content, or nil (caller falls back to the file icon).
    func thumbnail(for item: FileItem, size: CGFloat) async -> NSImage? {
        let previewable: Set<FileTypeCategory> = [.images, .video]
        guard !item.isArchiveEntry, previewable.contains(item.category) || item.ext == "pdf" else { return nil }

        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
        else { return nil }

        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}
