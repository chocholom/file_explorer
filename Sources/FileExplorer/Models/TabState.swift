import AppKit
import Observation

@MainActor
@Observable
final class TabState: Identifiable {
    enum Pane {
        case primary, secondary
    }

    let id = UUID()
    var primary: DirectoryViewModel
    var secondary: DirectoryViewModel?
    var activePane: Pane = .primary
    /// Pane currently under the mouse; a mouse-down there makes it active.
    var hoveredPane: Pane?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        primary = DirectoryViewModel(directory: directory)
    }

    init(snapshot: TabSnapshot) {
        primary = DirectoryViewModel(snapshot: snapshot.primary)
        if let secondarySnapshot = snapshot.secondary {
            secondary = DirectoryViewModel(snapshot: secondarySnapshot)
            activePane = snapshot.secondaryIsActive ? .secondary : .primary
        }
    }

    var snapshot: TabSnapshot {
        TabSnapshot(
            primary: primary.snapshot,
            secondary: secondary?.snapshot,
            secondaryIsActive: activePane == .secondary)
    }

    var activeModel: DirectoryViewModel {
        activePane == .secondary ? (secondary ?? primary) : primary
    }

    /// The pane that is *not* active (the target of F5/F6), if dual-pane is on.
    var otherModel: DirectoryViewModel? {
        guard let secondary else { return nil }
        return activePane == .primary ? secondary : primary
    }

    var isDualPane: Bool { secondary != nil }

    var title: String {
        let name = activeModel.currentDirectory.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    func toggleDualPane() {
        hoveredPane = nil
        if secondary == nil {
            secondary = DirectoryViewModel(directory: primary.currentDirectory)
            activePane = .secondary
        } else {
            secondary = nil
            activePane = .primary
        }
    }

    func togglePane() {
        guard isDualPane else { return }
        activePane = activePane == .primary ? .secondary : .primary
    }

    /// ⌘U in Total Commander: exchange the two panes (the active folder stays active).
    func swapPanes() {
        guard let secondary else { return }
        let formerPrimary = primary
        primary = secondary
        self.secondary = formerPrimary
        activePane = activePane == .primary ? .secondary : .primary
    }

    /// Target = Source: show the active pane's folder in the other pane too.
    func mirrorToOtherPane() {
        otherModel?.navigate(to: activeModel.currentDirectory)
    }

    /// Source = Target: jump the active pane to the other pane's folder.
    func adoptOtherPanePath() {
        guard let other = otherModel else { return }
        activeModel.navigate(to: other.currentDirectory)
    }

    /// Total Commander's "Compare Directories": in both panes, select the files that
    /// are missing on the other side or newer than their counterpart (same size and
    /// date within two seconds counts as identical; differing size marks both).
    /// Folders are not compared. Returns the number of marked files.
    @discardableResult
    func compareDirectories() -> Int {
        guard let other = otherModel else { return 0 }
        let active = activeModel

        func files(in model: DirectoryViewModel) -> [String: FileItem] {
            Dictionary(
                model.filteredItems.filter { !$0.isDirectory }.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first })
        }
        let activeFiles = files(in: active)
        let otherFiles = files(in: other)

        var activeSelection = Set<FileItem.ID>()
        var otherSelection = Set<FileItem.ID>()
        for (name, item) in activeFiles {
            guard let counterpart = otherFiles[name] else {
                activeSelection.insert(item.id)
                continue
            }
            let delta = item.modified.timeIntervalSince(counterpart.modified)
            if delta > 2 {
                activeSelection.insert(item.id)
            } else if delta < -2 {
                otherSelection.insert(counterpart.id)
            } else if item.size != counterpart.size {
                activeSelection.insert(item.id)
                otherSelection.insert(counterpart.id)
            }
        }
        for (name, item) in otherFiles where activeFiles[name] == nil {
            otherSelection.insert(item.id)
        }

        active.selection = activeSelection
        other.selection = otherSelection
        return activeSelection.count + otherSelection.count
    }
}

/// F5/F6 request awaiting confirmation in the copy/move sheet.
struct TransferRequest: Identifiable {
    let id = UUID()
    let kind: FileTransfer.Kind
    let items: [FileItem]
    let source: DirectoryViewModel
    let suggestedDestination: URL
}

struct SelectPatternRequest: Identifiable {
    let id = UUID()
    let select: Bool
}

@MainActor
@Observable
final class WindowState {
    let id = UUID()
    var tabs: [TabState]
    var selectedTabID: UUID
    var isKeyWindow = true
    var showingJumpPanel = false
    var showingCommandPalette = false
    var showingGoToFolder = false
    var transferRequest: TransferRequest?
    var selectPatternRequest: SelectPatternRequest?
    /// Transient status-bar message (e.g. "12 files marked"), cleared on the next action.
    var statusMessage: String?

    @ObservationIgnored private var eventMonitor: Any?

    init(session: SessionSnapshot? = nil) {
        if let session, !session.tabs.isEmpty {
            let restored = session.tabs.map { TabState(snapshot: $0) }
            let index = min(max(0, session.selectedIndex), restored.count - 1)
            tabs = restored
            selectedTabID = restored[index].id
        } else {
            let tab = TabState()
            tabs = [tab]
            selectedTabID = tab.id
        }
        WindowRegistry.shared.frontWindowID = id
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    var selectedTab: TabState? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The most recently key window hosts app-wide sheets (see `WindowRegistry`).
    var isFrontWindow: Bool { WindowRegistry.shared.frontWindowID == id }

    func becameKey() {
        isKeyWindow = true
        WindowRegistry.shared.frontWindowID = id
    }

    var activeModel: DirectoryViewModel {
        selectedTab?.activeModel ?? tabs[0].activeModel
    }

    var sessionSnapshot: SessionSnapshot {
        SessionSnapshot(
            tabs: tabs.map(\.snapshot),
            selectedIndex: tabs.firstIndex { $0.id == selectedTabID } ?? 0)
    }

    // MARK: Tabs

    func newTab() {
        let tab = TabState(directory: activeModel.currentDirectory)
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func closeTab(_ tab: TabState) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectNextTab(offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = (index + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    // MARK: Commander actions

    /// F5 / F6: confirm destination (prefilled with the other pane) in a sheet.
    func requestTransfer(_ kind: FileTransfer.Kind) {
        guard let tab = selectedTab else { return }
        let model = tab.activeModel
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        let destination = tab.otherModel?.currentDirectory ?? model.currentDirectory
        transferRequest = TransferRequest(
            kind: kind, items: items, source: model, suggestedDestination: destination)
    }

    func perform(_ request: TransferRequest, to destination: URL, policy: ConflictPolicy) {
        request.source.transfer(
            request.items.map(\.url), kind: request.kind, to: destination,
            forceMove: request.kind == .move, policy: policy)
    }

    func openSelection() {
        let model = activeModel
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        // Enter on a single folder or archive enters it; on files opens them all.
        if items.count == 1, items[0].isDirectory || items[0].isArchive {
            model.navigate(to: items[0].url)
        } else {
            model.open(items.filter { !$0.isDirectory })
        }
    }

    func toggleQuickLook() {
        let model = activeModel
        if model.quickLookItem != nil {
            model.quickLookItem = nil
        } else if let item = model.focusedItem {
            model.quickLook(item)
        }
    }

    /// Context-menu variant: extract the clicked archives rather than the selection.
    func extractSelectionOr(_ items: [FileItem]) {
        activeModel.selection = Set(items.map(\.id))
        extractSelection()
    }

    /// Unpacks the selected archives into the other pane's folder (or next to them).
    func extractSelection() {
        let model = activeModel
        let archives = model.selectedItems.filter(\.isArchive)
        guard !archives.isEmpty else {
            statusMessage = "Select an archive to extract"
            return
        }
        let destination = selectedTab?.otherModel?.currentDirectory ?? model.currentDirectory
        guard ArchiveLocator.locate(destination) == nil else {
            statusMessage = "Can't extract into another archive"
            return
        }
        for archive in archives {
            model.extract(archive, into: destination)
        }
    }

    func compareDirectories() {
        guard let tab = selectedTab, tab.isDualPane else {
            statusMessage = "Compare needs two panes (⇧⌘D)"
            return
        }
        let count = tab.compareDirectories()
        statusMessage = count == 0 ? "Folders are identical" : "\(count) differing files marked"
    }

    // MARK: Event handling

    /// Keys SwiftUI can't reliably intercept over an AppKit-backed Table, plus the
    /// Commander keyboard layer (Enter, Backspace, Tab, F2…F8). Mouse-downs make the
    /// hovered pane active.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isKeyWindow else { return event }

        if event.type != .keyDown {
            if let tab = selectedTab, let hovered = tab.hoveredPane, tab.isDualPane,
                event.window?.sheetParent == nil
            {
                tab.activePane = hovered
            }
            return event
        }

        // Never steal keys from a text field or a sheet.
        guard let keyWindow = NSApp.keyWindow, keyWindow.sheetParent == nil,
            !(keyWindow.firstResponder is NSTextView)
        else { return event }

        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let model = activeModel

        switch (event.keyCode, mods) {
        case (49, []):  // space → Quick Look
            if model.quickLookItem == nil, model.focusedItem == nil { return event }
            toggleQuickLook()
            return nil
        case (36, []), (76, []):  // return / enter → open
            guard !model.selection.isEmpty else { return event }
            openSelection()
            return nil
        case (51, []):  // backspace → parent folder
            guard model.canGoUp else { return event }
            model.goUp()
            return nil
        case (13, [.command]) where tabs.count > 1:  // ⌘W closes the tab while several are open
            if let tab = selectedTab { closeTab(tab) }
            return nil
        case (48, []):  // tab → other pane
            guard let tab = selectedTab, tab.isDualPane else { return event }
            tab.togglePane()
            return nil
        case (123...126, []) where model.viewMode == .grid:  // arrows in the grid
            return model.moveGridSelection(keyCode: event.keyCode) ? nil : event
        case (120, []):  // F2 rename
            model.beginRenamingSelection()
            return nil
        case (99, []):  // F3 view
            toggleQuickLook()
            return nil
        case (118, []):  // F4 edit
            model.edit(model.selectedItems)
            return nil
        case (118, [.shift]):  // ⇧F4 new file
            model.newFile()
            return nil
        case (96, []):  // F5 copy
            requestTransfer(.copy)
            return nil
        case (97, []):  // F6 move
            requestTransfer(.move)
            return nil
        case (97, [.shift]):  // ⇧F6 rename (Commander habit)
            model.beginRenamingSelection()
            return nil
        case (98, []):  // F7 new folder
            model.newFolder()
            return nil
        case (100, []):  // F8 trash
            model.trashSelection()
            return nil
        case (100, [.shift]):  // ⇧F8 delete permanently
            model.requestPermanentDelete(model.selectedItems)
            return nil
        default:
            return event
        }
    }
}
