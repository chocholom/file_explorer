import SwiftUI
import UniformTypeIdentifiers

extension FileItem {
    /// Finder icon for real files; type icon for archive entries (which don't exist on disk).
    var systemIcon: NSImage {
        if isArchiveEntry {
            let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Drag payload. Archive entries are extracted first (small files only, since a
    /// drag start is synchronous); folders inside archives can't be dragged out — use F5.
    func dragProvider() -> NSItemProvider {
        guard let entry = archiveEntry else { return NSItemProvider(object: url as NSURL) }
        guard !isDirectory, let real = ArchiveCache.shared.materializeIfSmall(entry, size: size) else {
            return NSItemProvider()
        }
        return NSItemProvider(object: real as NSURL)
    }
}

/// Async Quick Look thumbnail with file-icon fallback, used by grid cells and list rows.
struct ThumbnailView: View {
    let item: FileItem
    var size: CGFloat = 96
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            } else {
                Image(nsImage: item.systemIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.75, height: size * 0.75)
            }
        }
        .task(id: item.id) {
            thumbnail = await ThumbnailLoader.shared.thumbnail(for: item, size: size)
        }
    }
}

/// Hover a previewable file for a moment → floating preview popover (WhimFiles-style).
struct HoverPreviewModifier: ViewModifier {
    let item: FileItem
    @State private var showing = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                guard AppSettings.shared.hoverPreview, item.isPreviewable else {
                    showing = false
                    return
                }
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if !Task.isCancelled { showing = true }
                    }
                } else {
                    showing = false
                }
            }
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                HoverPreviewContent(item: item)
            }
    }
}

extension View {
    func hoverPreview(for item: FileItem) -> some View {
        modifier(HoverPreviewModifier(item: item))
    }
}

private struct HoverPreviewContent: View {
    let item: FileItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .frame(width: 120, height: 120)
            }
        }
        .frame(maxWidth: 440, maxHeight: 440)
        .padding(6)
        .task {
            image = await ThumbnailLoader.shared.thumbnail(for: item, size: 440)
        }
    }
}
