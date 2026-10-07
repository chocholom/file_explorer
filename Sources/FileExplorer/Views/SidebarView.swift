import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    let model: DirectoryViewModel
    /// Bumped on mount/unmount so the volumes section recomputes.
    @State private var volumesGeneration = 0
    @State private var headerTargeted = false

    var body: some View {
        let _ = volumesGeneration
        let store = FavoritesStore.shared
        let userFavorites = store.urls.filter { url in
            !favorites.contains { $0.url.path == url.path }
        }
        List(selection: selectionBinding) {
            Section {
                ForEach(favorites, id: \.url) { favorite in
                    Label(favorite.name, systemImage: favorite.symbol)
                        .tag(favorite.url)
                        .dropDestination(for: URL.self) { urls, _ in
                            model.moveOrCopy(urls, into: favorite.url)
                            return true
                        }
                }
                // Dropping a folder between the built-in rows adds it at the top of yours.
                .onInsert(of: [UTType.fileURL]) { _, providers in
                    addFavorites(from: providers, at: 0)
                }

                ForEach(userFavorites, id: \.self) { url in
                    Label {
                        Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .tag(url)
                    .help(PathInput.abbreviate(url))
                    .contextMenu {
                        Button("Remove from Favorites") { store.remove(url) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        model.moveOrCopy(urls, into: url)
                        return true
                    }
                }
                // Finder-style: drag a folder between rows to add it there.
                .onInsert(of: [UTType.fileURL]) { index, providers in
                    addFavorites(from: providers, at: index)
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }

                if userFavorites.isEmpty {
                    Text("Drag folders here to add favorites")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Favorites")
                    Spacer()
                    Button {
                        store.toggle(model.currentDirectory)
                    } label: {
                        Image(systemName: store.contains(model.currentDirectory) ? "star.fill" : "star")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isInsideArchive)
                    .help(store.contains(model.currentDirectory)
                        ? "Remove the current folder from Favorites" : "Add the current folder to Favorites")
                }
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(headerTargeted ? Color.accentColor.opacity(0.2) : .clear)
                        .padding(-4)
                )
                // Dropping onto the header appends.
                .dropDestination(for: URL.self) { urls, _ in
                    store.insert(urls, at: store.urls.count)
                    return urls.contains { FileSystemHelpers.isDirectory($0) }
                } isTargeted: { headerTargeted = $0 }
            }
            Section("Volumes") {
                ForEach(volumes, id: \.self) { url in
                    Label(volumeName(for: url), systemImage: "externaldrive")
                        .tag(url)
                        .dropDestination(for: URL.self) { urls, _ in
                            model.moveOrCopy(urls, into: url)
                            return true
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        ) { _ in volumesGeneration += 1 }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
        ) { _ in volumesGeneration += 1 }
    }

    /// Resolves dropped file URLs (from a pane or from Finder) and adds the folders.
    private func addFavorites(from providers: [NSItemProvider], at index: Int) {
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    box.append(url)
                } else if let url = item as? URL {
                    box.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            FavoritesStore.shared.insert(box.urls, at: index)
        }
    }

    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL] = []
        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { model.currentDirectory },
            set: { url in
                if let url { model.navigate(to: url) }
            }
        )
    }

    private struct Favorite {
        let name: String
        let url: URL
        let symbol: String
    }

    private var favorites: [Favorite] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [(String, URL, String)] = [
            ("Home", home, "house"),
            ("Desktop", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            ("Documents", home.appendingPathComponent("Documents"), "doc"),
            ("Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            ("Pictures", home.appendingPathComponent("Pictures"), "photo"),
            ("Movies", home.appendingPathComponent("Movies"), "film"),
            ("Music", home.appendingPathComponent("Music"), "music.note"),
            ("Applications", URL(fileURLWithPath: "/Applications"), "app.badge"),
        ]
        return candidates
            .filter { fm.fileExists(atPath: $0.1.path) }
            .map { Favorite(name: $0.0, url: $0.1.standardizedFileURL, symbol: $0.2) }
    }

    private var volumes: [URL] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map(\.standardizedFileURL)
    }

    private func volumeName(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? url.lastPathComponent
    }
}
