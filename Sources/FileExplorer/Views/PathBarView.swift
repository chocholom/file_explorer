import SwiftUI

struct PathBarView: View {
    let model: DirectoryViewModel
    @Environment(WindowState.self) private var state: WindowState?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(ancestors, id: \.self) { url in
                        Button {
                            model.navigate(to: url)
                        } label: {
                            Text(displayName(for: url))
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(url.path == model.currentDirectory.path ? .primary : .secondary)
                        .dropDestination(for: URL.self) { urls, _ in
                            model.moveOrCopy(urls, into: url)
                            return true
                        }

                        if url.path != model.currentDirectory.path {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Button {
                        state?.showingGoToFolder = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Go to Folder… (⇧⌘G)")
                    .padding(.leading, 4)
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 8)

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.trailing, 10)
                .layoutPriority(1)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.currentDirectory.path, forType: .string)
            }
            Button("Go to Folder…") { state?.showingGoToFolder = true }
            Divider()
            Button(FavoritesStore.shared.contains(model.currentDirectory) ? "Remove from Favorites" : "Add to Favorites") {
                FavoritesStore.shared.toggle(model.currentDirectory)
            }
            Button("Open in Terminal") { model.openInTerminal() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.currentDirectory])
            }
        }
    }

    private var ancestors: [URL] {
        // Note: deletingLastPathComponent() on "/" yields "/..", so stop on path == "/".
        var urls: [URL] = []
        var url = model.currentDirectory.standardizedFileURL
        while url.path != "/", urls.count < 64 {
            urls.append(url)
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        urls.append(URL(fileURLWithPath: "/"))
        return urls.reversed()
    }

    private func displayName(for url: URL) -> String {
        url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }

    /// Commander-style totals: "3 of 40 selected · 12 MB of 1.2 GB · 120 GB free".
    private var statusText: String {
        let items = model.filteredItems
        let selected = items.filter { model.selection.contains($0.id) }

        func bytes(_ list: [FileItem]) -> Int64 {
            list.reduce(0) { total, item in
                total + (item.isDirectory ? (FolderSizeStore.shared.size(for: item.url) ?? 0) : item.size)
            }
        }
        func format(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }

        var parts: [String] = []
        if !selected.isEmpty {
            parts.append("\(selected.count) of \(items.count) selected")
            parts.append("\(format(bytes(selected))) of \(format(bytes(items)))")
        } else {
            if model.searchRecursively && !model.searchText.isEmpty {
                parts.append("\(items.count) results")
            } else if model.hasActiveFilters {
                parts.append("\(items.count) of \(model.allItems.count) items")
            } else {
                parts.append("\(items.count) items")
            }
            let total = bytes(items)
            if total > 0 { parts.append(format(total)) }
        }
        if let free = model.freeSpace {
            parts.append("\(format(free)) free")
        }
        return parts.joined(separator: " · ")
    }
}
