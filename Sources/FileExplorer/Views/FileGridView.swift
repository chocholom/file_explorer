import SwiftUI

struct FileGridView: View {
    let model: DirectoryViewModel
    @State private var anchorID: FileItem.ID?

    private static let cellMinWidth: CGFloat = 110
    private static let spacing: CGFloat = 12

    private let columns = [
        GridItem(.adaptive(minimum: cellMinWidth, maximum: 150), spacing: spacing)
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.filteredItems) { item in
                        cell(for: item)
                            .id(item.id)
                    }
                }
                .padding(12)
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { updateColumnCount(width: geometry.size.width) }
                        .onChange(of: geometry.size.width) {
                            updateColumnCount(width: geometry.size.width)
                        }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                model.selection = []
            }
            .onChange(of: model.selection) {
                // Keep keyboard-navigated selection visible.
                if let first = model.selection.first {
                    proxy.scrollTo(first)
                }
            }
        }
    }

    private func updateColumnCount(width: CGFloat) {
        let available = width - 24 + Self.spacing
        model.gridColumnCount = max(1, Int(available / (Self.cellMinWidth + Self.spacing)))
    }

    @ViewBuilder
    private func cell(for item: FileItem) -> some View {
        GridCell(model: model, item: item, isSelected: model.selection.contains(item.id))
            .onDrag { item.dragProvider() }
            .gesture(
                TapGesture(count: 2).onEnded {
                    FileActions.open(item, in: model)
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    let modifiers = NSEvent.modifierFlags
                    if modifiers.contains(.shift), let anchorID,
                        let anchorIndex = model.filteredItems.firstIndex(where: { $0.id == anchorID }),
                        let clickedIndex = model.filteredItems.firstIndex(where: { $0.id == item.id })
                    {
                        let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
                        model.selection = Set(model.filteredItems[range].map(\.id))
                    } else if modifiers.contains(.command) {
                        if model.selection.contains(item.id) {
                            model.selection.remove(item.id)
                        } else {
                            model.selection.insert(item.id)
                        }
                        anchorID = item.id
                    } else {
                        model.selection = [item.id]
                        anchorID = item.id
                    }
                }
            )
            .contextMenu {
                FileContextMenu(model: model, items: contextItems(for: item))
            }
    }

    /// Right-click acts on the whole selection when the clicked item is part of it.
    private func contextItems(for item: FileItem) -> [FileItem] {
        model.selection.contains(item.id)
            ? model.filteredItems.filter { model.selection.contains($0.id) }
            : [item]
    }
}

private struct GridCell: View {
    let model: DirectoryViewModel
    let item: FileItem
    let isSelected: Bool
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(item: item, size: 96)
                .frame(width: 96, height: 96)
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .opacity(FileClipboard.shared.isCut(item.url) ? 0.45 : 1)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .hoverPreview(for: item)
        .dropDestination(for: URL.self) { urls, _ in
            guard item.isDirectory || item.isArchive else { return false }
            model.moveOrCopy(urls, into: item.url)
            return true
        } isTargeted: { targeting in
            isDropTarget = targeting && (item.isDirectory || item.isArchive)
        }
    }

    private var backgroundColor: Color {
        if isDropTarget { return Color.accentColor.opacity(0.35) }
        if isSelected { return Color.accentColor.opacity(0.2) }
        return .clear
    }
}
