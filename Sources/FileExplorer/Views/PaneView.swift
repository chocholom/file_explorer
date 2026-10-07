import QuickLook
import SwiftUI

/// One browsing pane: filter bar, file listing, path bar. A tab shows one or two of these.
struct PaneView: View {
    let model: DirectoryViewModel
    let isActive: Bool
    let showsActiveIndicator: Bool

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(model: model)
            Divider()
            content
            Divider()
            PathBarView(model: model)
        }
        .overlay(alignment: .top) {
            if showsActiveIndicator {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let activity = model.archiveActivity, !model.filteredItems.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 36)
                .padding(.trailing, 12)
            }
        }
        .quickLookPreview(quickLookBinding, in: quickLookItems)
        .sheet(item: renameTargetBinding) { item in
            RenameSheet(model: model, item: item)
        }
        .sheet(item: infoTargetBinding) { item in
            InfoSheet(item: item)
        }
        .sheet(item: batchRenameBinding) { request in
            BatchRenameSheet(model: model, items: request.items)
        }
        .alert("Operation Failed", isPresented: operationErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.operationError ?? "")
        }
        .alert(
            "Delete Permanently?", isPresented: permanentDeleteBinding,
            presenting: model.pendingPermanentDelete
        ) { _ in
            Button("Delete", role: .destructive) { model.confirmPermanentDelete() }
            Button("Cancel", role: .cancel) { model.pendingPermanentDelete = nil }
        } message: { items in
            Text(
                "\(items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items") will be deleted immediately, bypassing the Trash. You can't undo this."
            )
        }
    }

    /// Arrow keys browse the listing in Quick Look; inside an archive only the
    /// extracted file exists on disk, so the list is just that one.
    private var quickLookItems: [URL] {
        if model.isInsideArchive {
            return model.quickLookItem.map { [$0] } ?? []
        }
        return model.filteredItems.map(\.url)
    }

    @ViewBuilder
    private var content: some View {
        if let activity = model.archiveActivity, model.filteredItems.isEmpty, model.loadError == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.loadError {
            ContentUnavailableView(
                "Can't Open Folder",
                systemImage: "lock.fill",
                description: Text(error)
            )
            .frame(maxHeight: .infinity)
        } else if model.filteredItems.isEmpty {
            ContentUnavailableView(
                model.hasActiveFilters ? "No Matching Files" : "Empty Folder",
                systemImage: model.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "folder",
                description: model.hasActiveFilters
                    ? Text("No files match the active filters.")
                    : Text("This folder contains no visible items.")
            )
            .frame(maxHeight: .infinity)
            .contextMenu { FileContextMenu(model: model, items: []) }
            .dropDestination(for: URL.self) { urls, _ in
                model.moveOrCopy(urls, into: model.currentDirectory)
                return true
            }
        } else {
            switch model.viewMode {
            case .list:
                FileListView(model: model)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.moveOrCopy(urls, into: model.currentDirectory)
                        return true
                    }
            case .grid:
                FileGridView(model: model)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.moveOrCopy(urls, into: model.currentDirectory)
                        return true
                    }
            }
        }
    }

    private var quickLookBinding: Binding<URL?> {
        Binding(get: { model.quickLookItem }, set: { model.quickLookItem = $0 })
    }

    private var renameTargetBinding: Binding<FileItem?> {
        Binding(get: { model.renameTarget }, set: { model.renameTarget = $0 })
    }

    private var infoTargetBinding: Binding<FileItem?> {
        Binding(get: { model.infoTarget }, set: { model.infoTarget = $0 })
    }

    private var batchRenameBinding: Binding<BatchRenameRequest?> {
        Binding(get: { model.batchRenameRequest }, set: { model.batchRenameRequest = $0 })
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { model.operationError != nil },
            set: { if !$0 { model.operationError = nil } }
        )
    }

    private var permanentDeleteBinding: Binding<Bool> {
        Binding(
            get: { model.pendingPermanentDelete != nil },
            set: { if !$0 { model.pendingPermanentDelete = nil } }
        )
    }
}
