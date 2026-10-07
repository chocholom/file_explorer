import SwiftUI

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let shortcut: String?
    let run: () -> Void
}

/// ⇧⌘A command palette: fuzzy-filter common actions, Enter runs the selected one.
struct CommandPaletteView: View {
    let state: WindowState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(selectedIndex + 1, filteredActions.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(selectedIndex - 1, 0)
                        return .handled
                    }
                    .onSubmit(runSelected)
                    .onChange(of: query) { selectedIndex = 0 }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                            HStack(spacing: 8) {
                                Image(systemName: action.icon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(action.title)
                                Spacer()
                                if let shortcut = action.shortcut {
                                    Text(shortcut)
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(index == selectedIndex ? Color.accentColor.opacity(0.25) : .clear)
                            )
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                action.run()
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { proxy.scrollTo(selectedIndex) }
            }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(height: 0)
        }
        .padding(14)
        .frame(width: 480)
        .onAppear { fieldFocused = true }
    }

    private var filteredActions: [PaletteAction] {
        let actions = buildActions()
        let normalized = query.lowercased().replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return actions }
        return
            actions
            .compactMap { action -> (Int, PaletteAction)? in
                Fuzzy.score(query: normalized, candidate: action.title.lowercased())
                    .map { ($0, action) }
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    private func buildActions() -> [PaletteAction] {
        let model = state.activeModel
        let selected = model.selectedItems
        let tab = state.selectedTab
        let settings = AppSettings.shared
        var actions: [PaletteAction] = [
            .init(title: "New Tab", icon: "plus.rectangle", shortcut: "⌘T") { state.newTab() },
            .init(title: "New Folder", icon: "folder.badge.plus", shortcut: "⇧⌘N · F7") { model.newFolder() },
            .init(title: "New File", icon: "doc.badge.plus", shortcut: "⌥⌘N · ⇧F4") { model.newFile() },
            .init(title: "Go to Folder…", icon: "folder", shortcut: "⇧⌘G") { state.showingGoToFolder = true },
            .init(title: "Jump to Folder or File", icon: "arrowshape.turn.up.right", shortcut: "⇧⌘O") {
                state.showingJumpPanel = true
            },
            .init(title: "Toggle Dual Pane", icon: "rectangle.split.2x1", shortcut: "⇧⌘D") {
                tab?.toggleDualPane()
            },
            .init(title: "Select by Pattern…", icon: "checkmark.circle", shortcut: "⌘+") {
                state.selectPatternRequest = SelectPatternRequest(select: true)
            },
            .init(title: "Unselect by Pattern…", icon: "circle", shortcut: "⌘−") {
                state.selectPatternRequest = SelectPatternRequest(select: false)
            },
            .init(title: "Invert Selection", icon: "arrow.triangle.2.circlepath", shortcut: "⌘*") {
                model.invertSelection()
            },
            .init(title: "Open in Terminal", icon: "terminal", shortcut: nil) { model.openInTerminal() },
            .init(title: "Toggle Hidden Files", icon: "eye", shortcut: "⇧⌘.") { model.showHiddenFiles.toggle() },
            .init(
                title: settings.calculateFolderSizes ? "Stop Calculating Folder Sizes" : "Calculate Folder Sizes",
                icon: "folder.badge.gearshape", shortcut: nil
            ) { settings.calculateFolderSizes.toggle() },
            .init(
                title: settings.listThumbnails ? "Small Icons in List" : "Large Thumbnails in List",
                icon: "photo.on.rectangle", shortcut: nil
            ) { settings.listThumbnails.toggle() },
            .init(
                title: settings.hoverPreview ? "Disable Hover Preview" : "Enable Hover Preview",
                icon: "cursorarrow.motionlines", shortcut: nil
            ) { settings.hoverPreview.toggle() },
            .init(
                title: settings.showFunctionKeyBar ? "Hide Function Key Bar" : "Show Function Key Bar",
                icon: "keyboard", shortcut: nil
            ) { settings.showFunctionKeyBar.toggle() },
            .init(
                title: FavoritesStore.shared.contains(model.currentDirectory)
                    ? "Remove Current Folder from Favorites" : "Add Current Folder to Favorites",
                icon: "star", shortcut: nil
            ) { FavoritesStore.shared.toggle(model.currentDirectory) },
            .init(title: "Reveal Current Folder in Finder", icon: "arrow.up.forward.app", shortcut: nil) {
                NSWorkspace.shared.activateFileViewerSelecting([model.currentDirectory])
            },
        ]

        if let tab, tab.isDualPane {
            actions.append(contentsOf: [
                .init(title: "Swap Panes", icon: "arrow.left.arrow.right", shortcut: "⌘U") { tab.swapPanes() },
                .init(title: "Show This Folder in Other Pane", icon: "arrow.right.square", shortcut: "⌘→") {
                    tab.mirrorToOtherPane()
                },
                .init(title: "Go to Other Pane's Folder", icon: "arrow.left.square", shortcut: "⌘←") {
                    tab.adoptOtherPanePath()
                },
                .init(title: "Compare Directories", icon: "arrow.left.arrow.right.square", shortcut: "⇧⌘C") {
                    state.compareDirectories()
                },
            ])
        }

        if !selected.isEmpty {
            actions.append(contentsOf: [
                .init(title: "Copy to Other Pane…", icon: "doc.on.doc", shortcut: "F5") {
                    state.requestTransfer(.copy)
                },
                .init(title: "Move to Other Pane…", icon: "arrow.right.doc.on.clipboard", shortcut: "F6") {
                    state.requestTransfer(.move)
                },
                .init(title: "Edit", icon: "pencil.and.outline", shortcut: "F4") { model.edit(selected) },
                .init(title: "Move to Trash", icon: "trash", shortcut: "⌘⌫ · F8") { model.trashSelection() },
                .init(title: "Delete Immediately…", icon: "trash.slash", shortcut: "⌥⌘⌫ · ⇧F8") {
                    model.requestPermanentDelete(selected)
                },
                .init(title: "Duplicate", icon: "plus.square.on.square", shortcut: "⌘D") { model.duplicateSelection() },
                .init(title: "Compress Selection", icon: "archivebox", shortcut: nil) { model.compress(selected) },
                .init(title: "Select All with Same Extension", icon: "checkmark.circle.badge.questionmark", shortcut: "⌥⌘+") {
                    model.selectSameExtension()
                },
            ])
            if selected.contains(where: \.isArchive) {
                actions.append(
                    .init(title: "Extract Archive…", icon: "shippingbox.and.arrow.backward", shortcut: "⌥⌘E") {
                        state.extractSelection()
                    })
            }
            if selected.count > 1 {
                actions.append(
                    .init(title: "Batch Rename…", icon: "pencil.line", shortcut: "F2") {
                        model.batchRenameRequest = BatchRenameRequest(items: selected)
                    })
            } else {
                actions.append(
                    .init(title: "Rename…", icon: "pencil", shortcut: "F2") {
                        model.renameTarget = selected.first
                    })
                actions.append(
                    .init(title: "Get Info", icon: "info.circle", shortcut: "⌘I") {
                        model.infoTarget = selected.first
                    })
            }
            if selected.contains(where: { ImageConverter.canConvert($0) }) {
                actions.append(
                    .init(title: "Convert Image to JPG", icon: "photo", shortcut: nil) {
                        model.convertImages(selected, to: .jpg)
                    })
                actions.append(
                    .init(title: "Convert Image to PNG", icon: "photo", shortcut: nil) {
                        model.convertImages(selected, to: .png)
                    })
            }
        }
        return actions
    }

    private func runSelected() {
        let actions = filteredActions
        guard actions.indices.contains(selectedIndex) else { return }
        actions[selectedIndex].run()
        dismiss()
    }
}
