import SwiftUI

struct ContentView: View {
    @State private var state: WindowState
    @Environment(\.controlActiveState) private var controlActiveState

    init() {
        // The first window restores the previous session; ⌘N windows start fresh.
        _state = State(initialValue: WindowState(session: SessionStore.takeForLaunch()))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: state.activeModel)
        } detail: {
            VStack(spacing: 0) {
                TabBarView(state: state)
                Divider()
                if let tab = state.selectedTab {
                    TabContentView(tab: tab)
                        .id(tab.id)
                }
                OperationStatusView()
                if AppSettings.shared.showFunctionKeyBar {
                    Divider()
                    FunctionKeyBar(state: state)
                }
            }
        }
        .environment(state)
        .navigationTitle(windowTitle)
        .toolbar { toolbar }
        .focusedSceneValue(\.directoryModel, state.activeModel)
        .focusedSceneValue(\.windowState, state)
        .sheet(isPresented: jumpPanelBinding) {
            JumpPanelView(state: state)
        }
        .sheet(isPresented: commandPaletteBinding) {
            CommandPaletteView(state: state)
        }
        .sheet(isPresented: goToFolderBinding) {
            GoToFolderSheet(state: state)
        }
        .sheet(item: transferRequestBinding) { request in
            CopyMoveSheet(state: state, request: request)
        }
        .sheet(item: selectPatternBinding) { request in
            SelectPatternSheet(model: state.activeModel, select: request.select)
        }
        .sheet(item: conflictBinding) { conflict in
            ConflictSheet(conflict: conflict)
                .interactiveDismissDisabled()
        }
        .onAppear {
            if controlActiveState == .key { state.becameKey() }
        }
        .onChange(of: controlActiveState) {
            if controlActiveState == .key {
                state.becameKey()
            } else {
                state.isKeyWindow = false
            }
        }
        .onChange(of: state.sessionSnapshot) { _, snapshot in
            SessionStore.save(snapshot)
        }
        .task(id: state.statusMessage) {
            // Status messages fade after a few seconds.
            guard state.statusMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { state.statusMessage = nil }
        }
    }

    private var windowTitle: String {
        let name = state.activeModel.currentDirectory.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                state.activeModel.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!state.activeModel.canGoBack)
            .help("Back (⌘[)")

            Button {
                state.activeModel.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!state.activeModel.canGoForward)
            .help("Forward (⌘])")

            Button {
                state.activeModel.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!state.activeModel.canGoUp)
            .help("Enclosing Folder (⌘↑ or ⌫)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.showingJumpPanel = true
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }
            .help("Jump to Folder or File (⇧⌘O)")

            Button {
                state.selectedTab?.toggleDualPane()
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .symbolVariant(state.selectedTab?.isDualPane == true ? .fill : .none)
            }
            .help("Toggle Dual Pane (⇧⌘D)")

            if state.selectedTab?.isDualPane == true {
                Button {
                    state.selectedTab?.swapPanes()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Swap Panes (⌘U)")
            }

            Button {
                state.activeModel.newFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N or F7)")

            Picker("View", selection: viewModeBinding) {
                Image(systemName: "list.bullet").tag(DirectoryViewModel.ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(DirectoryViewModel.ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("List (⌘1) / Grid (⌘2)")

            Menu {
                Picker("Sort By", selection: sortFieldBinding) {
                    ForEach(DirectoryViewModel.SortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                Toggle("Ascending", isOn: sortAscendingBinding)
                Divider()
                Toggle("Show Hidden Files", isOn: showHiddenBinding)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort & view options")
        }
    }

    private var viewModeBinding: Binding<DirectoryViewModel.ViewMode> {
        Binding(get: { state.activeModel.viewMode }, set: { state.activeModel.viewMode = $0 })
    }

    private var sortFieldBinding: Binding<DirectoryViewModel.SortField> {
        Binding(get: { state.activeModel.sortField }, set: { state.activeModel.sortField = $0 })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { state.activeModel.sortAscending }, set: { state.activeModel.sortAscending = $0 })
    }

    private var showHiddenBinding: Binding<Bool> {
        Binding(get: { state.activeModel.showHiddenFiles }, set: { state.activeModel.showHiddenFiles = $0 })
    }

    private var jumpPanelBinding: Binding<Bool> {
        Binding(get: { state.showingJumpPanel }, set: { state.showingJumpPanel = $0 })
    }

    private var commandPaletteBinding: Binding<Bool> {
        Binding(get: { state.showingCommandPalette }, set: { state.showingCommandPalette = $0 })
    }

    private var goToFolderBinding: Binding<Bool> {
        Binding(get: { state.showingGoToFolder }, set: { state.showingGoToFolder = $0 })
    }

    private var transferRequestBinding: Binding<TransferRequest?> {
        Binding(get: { state.transferRequest }, set: { state.transferRequest = $0 })
    }

    private var selectPatternBinding: Binding<SelectPatternRequest?> {
        Binding(get: { state.selectPatternRequest }, set: { state.selectPatternRequest = $0 })
    }

    /// The shared queue's conflict is shown in the front window only.
    private var conflictBinding: Binding<FileConflict?> {
        Binding(
            get: { state.isFrontWindow ? FileOperationQueue.shared.pendingConflict : nil },
            set: { value in
                if value == nil, FileOperationQueue.shared.pendingConflict != nil {
                    FileOperationQueue.shared.resolvePendingConflict(.cancel, applyToAll: false)
                }
            })
    }
}

struct TabContentView: View {
    let tab: TabState

    var body: some View {
        if let secondary = tab.secondary {
            HSplitView {
                PaneView(model: tab.primary, isActive: tab.activePane == .primary, showsActiveIndicator: true)
                    .id(ObjectIdentifier(tab.primary))
                    .frame(minWidth: 320)
                    .onHover { hovering in setHovered(.primary, hovering) }

                PaneView(model: secondary, isActive: tab.activePane == .secondary, showsActiveIndicator: true)
                    .id(ObjectIdentifier(secondary))
                    .frame(minWidth: 320)
                    .onHover { hovering in setHovered(.secondary, hovering) }
            }
        } else {
            PaneView(model: tab.primary, isActive: true, showsActiveIndicator: false)
                .id(ObjectIdentifier(tab.primary))
        }
    }

    /// A mouse-down in the hovered pane makes it active (see `WindowState.handle`).
    private func setHovered(_ pane: TabState.Pane, _ hovering: Bool) {
        if hovering {
            tab.hoveredPane = pane
        } else if tab.hoveredPane == pane {
            tab.hoveredPane = nil
        }
    }
}

// MARK: - Shared actions

@MainActor
enum FileActions {
    /// Folders and archives are entered; files open in their default app.
    static func open(_ item: FileItem, in model: DirectoryViewModel) {
        if item.isDirectory || item.isArchive {
            model.navigate(to: item.url)
        } else {
            model.open([item])
        }
    }

    static func revealInFinder(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    static func copyPath(_ item: FileItem) {
        copyPaths([item])
    }

    static func copyPaths(_ items: [FileItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
    }
}

struct RenameSheet: View {
    let model: DirectoryViewModel
    let item: FileItem
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(item.name)”")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($fieldFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            name = item.name
            fieldFocused = true
            selectStem()
        }
    }

    /// Finder-style: start with the name selected but not the extension.
    private func selectStem() {
        guard !item.isDirectory, !item.ext.isEmpty else { return }
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let stemLength = (item.name as NSString).deletingPathExtension.utf16.count
            editor.setSelectedRange(NSRange(location: 0, length: stemLength))
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        model.rename(item, to: trimmedName)
        dismiss()
    }
}
