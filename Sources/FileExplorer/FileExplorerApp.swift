import SwiftUI

@main
struct FileExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            FileCommands()
        }
    }
}

struct FileCommands: Commands {
    @FocusedValue(\.directoryModel) private var model
    @FocusedValue(\.windowState) private var windowState

    /// The field editor when the user is typing in any text field. Menu key
    /// equivalents outrank text views, so edit commands must forward to it —
    /// otherwise ⌘C in the search field would copy *files*.
    private var textEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private var tab: TabState? { windowState?.selectedTab }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(UndoStack.shared.topName.map { "Undo \($0)" } ?? "Undo") {
                if let textEditor, textEditor.undoManager?.canUndo == true {
                    textEditor.undoManager?.undo()
                } else {
                    UndoStack.shared.undo()
                }
            }
            .keyboardShortcut("z")
        }

        // MARK: File
        CommandGroup(after: .newItem) {
            Button("New Tab") { windowState?.newTab() }
                .keyboardShortcut("t")
                .disabled(windowState == nil)
            Button("New Folder") { model?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("New File") { model?.newFile() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button("Open") { windowState?.openSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(model == nil)
            Button("Quick Look") { windowState?.toggleQuickLook() }
                .disabled(model == nil)
            Button("Edit (F4)") {
                guard let model else { return }
                model.edit(model.selectedItems)
            }
            .disabled(model == nil)
            Button("Get Info") {
                model?.infoTarget = model?.selectedItems.first
            }
            .keyboardShortcut("i")
            .disabled(model == nil)
            Divider()
            Button("Compress") {
                guard let model else { return }
                model.compress(model.selectedItems)
            }
            .disabled(model == nil || model?.isInsideArchive == true)
            Button("Extract Archive…") { windowState?.extractSelection() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model?.selectedItems.contains(where: \.isArchive) != true)
            Button("Open in Terminal") { model?.openInTerminal() }
                .disabled(model == nil)
            Divider()
            Button("Jump to Folder or File…") { windowState?.showingJumpPanel = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(windowState == nil)
            Button("Command Palette…") { windowState?.showingCommandPalette = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(windowState == nil)
            Divider()
            Button("Close Tab") {
                if let windowState, let tab = windowState.selectedTab { windowState.closeTab(tab) }
            }
            .disabled((windowState?.tabs.count ?? 0) < 2)
        }

        // MARK: Edit
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if let textEditor {
                    textEditor.cut(nil)
                } else {
                    model?.cutSelectionToPasteboard()
                }
            }
            .keyboardShortcut("x")
            Button("Copy") {
                if let textEditor {
                    textEditor.copy(nil)
                } else {
                    model?.copySelectionToPasteboard()
                }
            }
            .keyboardShortcut("c")
            Button("Paste") {
                if let textEditor {
                    textEditor.paste(nil)
                } else {
                    model?.pasteFromPasteboard()
                }
            }
            .keyboardShortcut("v")
            Button("Copy Path") {
                if let model { FileActions.copyPaths(model.selectedItems) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Duplicate") {
                guard textEditor == nil else { return }
                model?.duplicateSelection()
            }
            .keyboardShortcut("d")
            Button("Select All") {
                if let textEditor {
                    textEditor.selectAll(nil)
                } else {
                    model?.selectAll()
                }
            }
            .keyboardShortcut("a")
            Divider()
            Button("Rename…") { model?.beginRenamingSelection() }
                .disabled(model == nil)
            Button("Move to Trash") {
                if let textEditor {
                    textEditor.deleteToBeginningOfLine(nil)  // standard ⌘⌫ in text
                } else {
                    model?.trashSelection()
                }
            }
            .keyboardShortcut(.delete)
            Button("Delete Immediately…") {
                guard textEditor == nil, let model else { return }
                model.requestPermanentDelete(model.selectedItems)
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
        }

        // MARK: Mark (Total Commander's selection menu)
        CommandMenu("Mark") {
            Button("Select by Pattern…") {
                windowState?.selectPatternRequest = SelectPatternRequest(select: true)
            }
            .keyboardShortcut("+")
            .disabled(windowState == nil)
            Button("Unselect by Pattern…") {
                windowState?.selectPatternRequest = SelectPatternRequest(select: false)
            }
            .keyboardShortcut("-")
            .disabled(windowState == nil)
            Button("Invert Selection") {
                guard textEditor == nil else { return }
                model?.invertSelection()
            }
            .keyboardShortcut("*")
            .disabled(model == nil)
            Button("Select All with Same Extension") { model?.selectSameExtension() }
                .keyboardShortcut("+", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button("Compare Directories") { windowState?.compareDirectories() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(tab?.isDualPane != true)
        }

        // MARK: Go
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.canGoBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.canGoForward != true)
            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(model?.canGoUp != true)
            Divider()
            Button("Home") { model?.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Go to Folder…") { windowState?.showingGoToFolder = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(windowState == nil)
            Divider()
            Button(
                model.map { FavoritesStore.shared.contains($0.currentDirectory) } == true
                    ? "Remove Current Folder from Favorites" : "Add Current Folder to Favorites"
            ) {
                if let model { FavoritesStore.shared.toggle(model.currentDirectory) }
            }
            .disabled(model == nil)
            if !FavoritesStore.shared.urls.isEmpty {
                Divider()
                ForEach(FavoritesStore.shared.urls, id: \.self) { url in
                    Button(PathInput.abbreviate(url)) { model?.navigate(to: url) }
                        .disabled(model == nil)
                }
            }
        }

        // MARK: Panes
        CommandMenu("Panes") {
            Button("Toggle Dual Pane") { tab?.toggleDualPane() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Button("Switch Pane (Tab)") { tab?.togglePane() }
                .disabled(tab?.isDualPane != true)
            Button("Swap Panes") {
                guard textEditor == nil else { return }
                tab?.swapPanes()
            }
            .keyboardShortcut("u")
            .disabled(tab?.isDualPane != true)
            Button("Show This Folder in Other Pane") {
                guard textEditor == nil else { return }
                tab?.mirrorToOtherPane()
            }
            .keyboardShortcut(.rightArrow)
            .disabled(tab?.isDualPane != true)
            Button("Go to Other Pane's Folder") {
                guard textEditor == nil else { return }
                tab?.adoptOtherPanePath()
            }
            .keyboardShortcut(.leftArrow)
            .disabled(tab?.isDualPane != true)
            Divider()
            Button("Copy to Other Pane… (F5)") { windowState?.requestTransfer(.copy) }
                .disabled(model?.selection.isEmpty != false)
            Button("Move to Other Pane… (F6)") { windowState?.requestTransfer(.move) }
                .disabled(model?.selection.isEmpty != false)
            Divider()
            Button("Next Tab") { windowState?.selectNextTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((windowState?.tabs.count ?? 0) < 2)
            Button("Previous Tab") { windowState?.selectNextTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((windowState?.tabs.count ?? 0) < 2)
        }

        // MARK: View
        CommandGroup(after: .sidebar) {
            Toggle("Show Hidden Files", isOn: showHiddenBinding)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Calculate Folder Sizes", isOn: settingBinding(\.calculateFolderSizes))
            Toggle("Large Thumbnails in List", isOn: settingBinding(\.listThumbnails))
            Toggle("Hover Preview", isOn: settingBinding(\.hoverPreview))
            Toggle("Show Function Key Bar", isOn: settingBinding(\.showFunctionKeyBar))
            Divider()
            Button("as List") { model?.viewMode = .list }
                .keyboardShortcut("1")
                .disabled(model == nil)
            Button("as Grid") { model?.viewMode = .grid }
                .keyboardShortcut("2")
                .disabled(model == nil)
            Picker("Sort By", selection: sortFieldBinding) {
                ForEach(DirectoryViewModel.SortField.allCases, id: \.self) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .disabled(model == nil)
            Toggle("Sort Ascending", isOn: sortAscendingBinding)
                .disabled(model == nil)
            Divider()
        }
    }

    private var showHiddenBinding: Binding<Bool> {
        Binding(
            get: { model?.showHiddenFiles ?? false },
            set: { model?.showHiddenFiles = $0 }
        )
    }

    private var sortFieldBinding: Binding<DirectoryViewModel.SortField> {
        Binding(
            get: { model?.sortField ?? .name },
            set: { model?.sortField = $0 }
        )
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(
            get: { model?.sortAscending ?? true },
            set: { model?.sortAscending = $0 }
        )
    }

    private func settingBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { AppSettings.shared[keyPath: keyPath] },
            set: { AppSettings.shared[keyPath: keyPath] = $0 }
        )
    }
}

struct DirectoryModelFocusedKey: FocusedValueKey {
    typealias Value = DirectoryViewModel
}

struct WindowStateFocusedKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var directoryModel: DirectoryViewModel? {
        get { self[DirectoryModelFocusedKey.self] }
        set { self[DirectoryModelFocusedKey.self] = newValue }
    }

    var windowState: WindowState? {
        get { self[WindowStateFocusedKey.self] }
        set { self[WindowStateFocusedKey.self] = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no app bundle): show in Dock and take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Extracted archive entries live in Caches; drop folders untouched for a week.
        Task.detached(priority: .background) { ArchiveCache.shared.purge() }
    }
}
