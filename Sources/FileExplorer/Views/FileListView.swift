import SwiftUI

struct FileListView: View {
    let model: DirectoryViewModel
    @State private var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name)]

    var body: some View {
        Table(of: FileItem.self, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    if AppSettings.shared.listThumbnails {
                        ThumbnailView(item: item, size: 44)
                            .frame(width: 44, height: 44)
                    } else {
                        FileIconView(item: item)
                            .frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let searchPath = item.searchPath {
                            Text(searchPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .opacity(FileClipboard.shared.isCut(item.url) ? 0.45 : 1)
                .hoverPreview(for: item)
            }
            TableColumn("Size", value: \.size) { item in
                SizeCell(item: item)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.dateText)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160, max: 200)
            TableColumn("Kind", value: \.kindText) { item in
                Text(item.kindText)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70, max: 120)
        } rows: {
            ForEach(model.filteredItems) { item in
                TableRow(item)
                    .itemProvider { item.dragProvider() }
                    .dropDestination(for: URL.self) { urls in
                        // Dropping onto an archive copies into it (Commander behaviour).
                        guard item.isDirectory || item.isArchive else { return }
                        model.moveOrCopy(urls, into: item.url)
                    }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            FileContextMenu(model: model, items: items(in: ids))
        } primaryAction: { ids in
            for item in items(in: ids) {
                FileActions.open(item, in: model)
            }
        }
        .onAppear(perform: syncSortOrderFromModel)
        .onChange(of: model.sortField) { syncSortOrderFromModel() }
        .onChange(of: model.sortAscending) { syncSortOrderFromModel() }
        .onChange(of: sortOrder) { applySortOrderToModel() }
    }

    // MARK: Column-header sorting ↔ model sort state

    private static let fields: [(keyPath: PartialKeyPath<FileItem>, field: DirectoryViewModel.SortField)] = [
        (\FileItem.name, .name), (\FileItem.size, .size), (\FileItem.modified, .date), (\FileItem.kindText, .kind),
    ]

    private func syncSortOrderFromModel() {
        guard let entry = Self.fields.first(where: { $0.field == model.sortField }) else { return }
        let order: SortOrder = model.sortAscending ? .forward : .reverse
        let desired: [KeyPathComparator<FileItem>]
        switch entry.keyPath {
        case \FileItem.size: desired = [KeyPathComparator(\.size, order: order)]
        case \FileItem.modified: desired = [KeyPathComparator(\.modified, order: order)]
        case \FileItem.kindText: desired = [KeyPathComparator(\.kindText, order: order)]
        default: desired = [KeyPathComparator(\.name, order: order)]
        }
        if sortOrder != desired { sortOrder = desired }
    }

    private func applySortOrderToModel() {
        guard let first = sortOrder.first,
            let entry = Self.fields.first(where: { $0.keyPath == first.keyPath })
        else { return }
        if model.sortField != entry.field { model.sortField = entry.field }
        let ascending = first.order == .forward
        if model.sortAscending != ascending { model.sortAscending = ascending }
    }

    private var selectionBinding: Binding<Set<FileItem.ID>> {
        Binding(get: { model.selection }, set: { model.selection = $0 })
    }

    private func items(in ids: Set<FileItem.ID>) -> [FileItem] {
        model.filteredItems.filter { ids.contains($0.id) }
    }
}

/// File size, or the async-computed folder total when that mode is on.
private struct SizeCell: View {
    let item: FileItem

    var body: some View {
        Group {
            if item.isDirectory, AppSettings.shared.calculateFolderSizes {
                if let total = FolderSizeStore.shared.size(for: item.url) {
                    Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                } else {
                    Text("…")
                        .onAppear { FolderSizeStore.shared.request(item.url) }
                }
            } else {
                Text(item.sizeText)
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

struct FileIconView: View {
    let item: FileItem

    var body: some View {
        Image(nsImage: item.systemIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

/// Shared right-click menu for list rows, grid cells and empty space. Shortcut hints
/// match the real global shortcuts wired in FileCommands / the key monitor.
struct FileContextMenu: View {
    let model: DirectoryViewModel
    let items: [FileItem]
    @Environment(WindowState.self) private var state: WindowState?

    private var insideArchive: Bool { model.isInsideArchive }
    private var inArchiveEntries: Bool { items.contains(where: \.isArchiveEntry) }

    var body: some View {
        if items.isEmpty {
            if model.canModifyHere {
                Button("New Folder") { model.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            if !insideArchive {
                Button("New File") { model.newFile() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            if model.canModifyHere {
                Button(insideArchive ? "Paste into Archive" : "Paste") { model.pasteFromPasteboard() }
                    .keyboardShortcut("v")
            }
            Divider()
            Button("Select by Pattern…") { state?.selectPatternRequest = SelectPatternRequest(select: true) }
            if !insideArchive {
                Divider()
                Button("Open in Terminal") { model.openInTerminal() }
                Button(isFavorite(model.currentDirectory) ? "Remove from Favorites" : "Add to Favorites") {
                    FavoritesStore.shared.toggle(model.currentDirectory)
                }
            }
        } else {
            let single = items.count == 1 ? items[0] : nil
            Button(single?.isArchive == true ? "Open as Folder" : "Open") {
                for item in items { FileActions.open(item, in: model) }
            }
            .keyboardShortcut(.downArrow)
            if let single, single.isArchive {
                Button("Extract Archive…") { state?.extractSelectionOr(items) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Open with Default App") { model.open([single]) }
            }
            openWithMenu
            Button("Quick Look") {
                model.selection = Set(items.map(\.id))
                model.quickLook(items[0])
            }
            .keyboardShortcut(.space, modifiers: [])
            Button(inArchiveEntries ? "Edit Extracted Copy" : "Edit") { model.edit(items) }
            if let single {
                Button("Reveal in Finder") {
                    FileActions.revealInFinder(single.archiveEntry.map { FileItem(url: $0.archiveURL) ?? single } ?? single)
                }
                if single.isDirectory, !single.isArchiveEntry {
                    Button("Open in Terminal") { model.openInTerminal(single.url) }
                }
                Button("Get Info") { model.infoTarget = single }
                    .keyboardShortcut("i")
            }
            Divider()
            if model.canModifyHere {
                if let single {
                    Button("Rename…") { model.renameTarget = single }
                } else if !insideArchive {
                    Button("Batch Rename…") {
                        model.batchRenameRequest = BatchRenameRequest(items: items)
                    }
                }
            }
            if !insideArchive {
                Button("Duplicate") { model.duplicate(items) }
                    .keyboardShortcut("d")
                if items.contains(where: { ImageConverter.canConvert($0) }) {
                    Menu("Convert Image") {
                        ForEach(ImageConverter.Format.allCases, id: \.self) { format in
                            Button("To \(format.rawValue)") {
                                model.convertImages(items, to: format)
                            }
                        }
                    }
                }
                Button(items.count == 1 ? "Compress" : "Compress \(items.count) Items") {
                    model.compress(items)
                }
            }
            Divider()
            if let state, state.selectedTab?.isDualPane == true {
                Button("Copy to Other Pane (F5)") { transferToOtherPane(.copy, state: state) }
                if !inArchiveEntries || model.isArchiveWritable {
                    Button("Move to Other Pane (F6)") { transferToOtherPane(.move, state: state) }
                }
            }
            if !inArchiveEntries {
                Button("Cut") { model.cutToPasteboard(items) }
                    .keyboardShortcut("x")
            }
            Button("Copy") { model.copyToPasteboard(items) }
                .keyboardShortcut("c")
            Button(items.count == 1 ? "Copy Path" : "Copy Paths") { FileActions.copyPaths(items) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            if let single, single.isDirectory, !single.isArchiveEntry {
                Button(isFavorite(single.url) ? "Remove from Favorites" : "Add to Favorites") {
                    FavoritesStore.shared.toggle(single.url)
                }
            }
            Button("Select All with Same Extension") {
                model.selection = Set(items.map(\.id))
                model.selectSameExtension()
            }
            Divider()
            if inArchiveEntries {
                if model.isArchiveWritable {
                    Button("Delete from Archive…", role: .destructive) { model.requestPermanentDelete(items) }
                        .keyboardShortcut(.delete)
                }
            } else {
                Button("Move to Trash", role: .destructive) { model.trash(items) }
                    .keyboardShortcut(.delete)
                Button("Delete Immediately…", role: .destructive) { model.requestPermanentDelete(items) }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
            }
        }
    }

    @ViewBuilder
    private var openWithMenu: some View {
        let applications = DirectoryViewModel.applications(toOpen: items)
        if !applications.isEmpty {
            Menu("Open With") {
                ForEach(applications, id: \.self) { app in
                    Button {
                        model.open(items, with: app)
                    } label: {
                        Label {
                            Text(FileManager.default.displayName(atPath: app.path))
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        }
                    }
                }
            }
        }
    }

    private func isFavorite(_ url: URL) -> Bool {
        FavoritesStore.shared.contains(url)
    }

    private func transferToOtherPane(_ kind: FileTransfer.Kind, state: WindowState) {
        model.selection = Set(items.map(\.id))
        state.requestTransfer(kind)
    }
}
