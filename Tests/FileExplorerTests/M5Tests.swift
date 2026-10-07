import XCTest

@testable import FileExplorer

// MARK: - Pure helpers

final class NamePatternTests: XCTestCase {
    func testWildcardsAreCaseInsensitive() {
        XCTAssertTrue(NamePattern.matches("Photo.JPG", text: "*.jpg"))
        XCTAssertTrue(NamePattern.matches("IMG_0001.heic", text: "img_????.heic"))
        XCTAssertFalse(NamePattern.matches("notes.txt", text: "*.jpg"))
    }

    func testSeveralPatternsAndSubstringFallback() {
        XCTAssertEqual(NamePattern.parse("*.jpg; *.png  report"), ["*.jpg", "*.png", "report"])
        XCTAssertTrue(NamePattern.matches("shot.png", text: "*.jpg; *.png"))
        XCTAssertTrue(NamePattern.matches("Annual Report 2026.pdf", text: "report"))
        XCTAssertFalse(NamePattern.matches("Annual Report 2026.pdf", patterns: []))
    }
}

final class PathInputTests: XCTestCase {
    func testTildeAbsoluteAndRelative() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let base = URL(fileURLWithPath: "/tmp/base")
        XCTAssertEqual(PathInput.resolve("~", relativeTo: base)?.path, home.path)
        XCTAssertEqual(PathInput.resolve("~/Downloads", relativeTo: base)?.path, home.path + "/Downloads")
        XCTAssertEqual(PathInput.resolve("/Applications/", relativeTo: base)?.path, "/Applications")
        XCTAssertEqual(PathInput.resolve("sub/dir", relativeTo: base)?.path, "/tmp/base/sub/dir")
        XCTAssertEqual(PathInput.resolve("../x", relativeTo: base)?.path, "/tmp/x")
        XCTAssertNil(PathInput.resolve("   ", relativeTo: base))
        XCTAssertEqual(PathInput.abbreviate(home.appendingPathComponent("Movies")), "~/Movies")
        XCTAssertEqual(PathInput.abbreviate(URL(fileURLWithPath: "/Volumes/Data")), "/Volumes/Data")
    }
}

final class FileSystemHelpersTests: XCTestCase {
    func testUniqueDestinationAndBoundaryInvalidation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerHelpers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("a copy.txt"))

        XCTAssertEqual(
            FileSystemHelpers.uniqueDestination(for: "a.txt", in: dir).lastPathComponent, "a copy 2.txt")
        XCTAssertEqual(
            FileSystemHelpers.uniqueDestination(for: "b.txt", in: dir).lastPathComponent, "b.txt")

        // A broken symlink "exists" for naming purposes.
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("broken"), withDestinationURL: dir.appendingPathComponent("nope"))
        XCTAssertTrue(FileSystemHelpers.exists(dir.appendingPathComponent("broken")))
        XCTAssertFalse(FileSystemHelpers.exists(dir.appendingPathComponent("nope")))
    }
}

// MARK: - Selection & sorting

@MainActor
final class SelectionTests: XCTestCase {
    var fixtureDir: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerSelection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.png", "notes.txt"] {
            try Data("x".utf8).write(to: fixtureDir.appendingPathComponent(name))
        }
        model = DirectoryViewModel(directory: fixtureDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func names(_ ids: Set<FileItem.ID>) -> [String] {
        model.filteredItems.filter { ids.contains($0.id) }.map(\.name)
    }

    func testSelectByPatternInvertAndSameExtension() {
        model.select(matching: "*.jpg")
        XCTAssertEqual(names(model.selection), ["a.jpg", "b.jpg"])

        model.select(matching: "*.png; notes", select: true)
        XCTAssertEqual(names(model.selection), ["a.jpg", "b.jpg", "c.png", "notes.txt"])

        model.select(matching: "b*", select: false)
        XCTAssertEqual(names(model.selection), ["a.jpg", "c.png", "notes.txt"])

        model.invertSelection()
        XCTAssertEqual(names(model.selection), ["folder", "b.jpg"])

        model.selection = [model.filteredItems.first { $0.name == "a.jpg" }!.id]
        model.selectSameExtension()
        XCTAssertEqual(names(model.selection), ["a.jpg", "b.jpg"])
        XCTAssertEqual(model.focusedItem?.name, "a.jpg")

        model.selectAll()
        XCTAssertEqual(model.selection.count, 5)
    }

    func testSortByKindKeepsFoldersFirstAndTiesByName() {
        model.sortField = .kind
        XCTAssertEqual(model.filteredItems.map(\.name), ["folder", "a.jpg", "b.jpg", "c.png", "notes.txt"])
        model.sortAscending = false
        XCTAssertEqual(model.filteredItems.map(\.name), ["folder", "notes.txt", "c.png", "b.jpg", "a.jpg"])
    }

    func testFilteredItemsIsCachedUntilInputsChange() {
        let before = model.filteredItems
        XCTAssertEqual(before.count, 5)
        model.toggleCategory(.images)
        XCTAssertEqual(model.filteredItems.count, 3)
        model.clearFilters()
        XCTAssertEqual(model.filteredItems.count, 5)
    }

    func testGoUpSelectsTheFolderWeCameFrom() {
        model.navigate(to: fixtureDir.appendingPathComponent("folder"))
        model.goUp()
        XCTAssertEqual(names(model.selection), ["folder"])
    }

    func testVanishedFolderFallsBackToNearestAncestor() throws {
        let deep = fixtureDir.appendingPathComponent("folder/deeper")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        model.navigate(to: deep)
        try FileManager.default.removeItem(at: fixtureDir.appendingPathComponent("folder"))
        model.reload()
        XCTAssertEqual(model.currentDirectory.lastPathComponent, fixtureDir.lastPathComponent)
        XCTAssertNil(model.loadError)
    }

    func testSnapshotRoundTrip() {
        model.viewMode = .grid
        model.sortField = .date
        model.sortAscending = false
        let restored = DirectoryViewModel(snapshot: model.snapshot)
        XCTAssertEqual(restored.currentDirectory, model.currentDirectory)
        XCTAssertEqual(restored.viewMode, .grid)
        XCTAssertEqual(restored.sortField, .date)
        XCTAssertFalse(restored.sortAscending)

        let missing = DirectoryViewModel(snapshot: PaneSnapshot(
            path: "/definitely/not/here", viewMode: "List", sortField: "Name",
            sortAscending: true, showHiddenFiles: false))
        XCTAssertEqual(missing.currentDirectory, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }
}

// MARK: - Transfer engine

@MainActor
final class TransferEngineTests: XCTestCase {
    var root: URL!
    var source: URL!
    var target: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        UndoStack.shared.clear()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerTransfer-\(UUID().uuidString)")
        source = root.appendingPathComponent("src")
        target = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("a.txt"))
        model = DirectoryViewModel(directory: source)
    }

    override func tearDown() async throws {
        UndoStack.shared.clear()
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func exists(_ url: URL) -> Bool { FileSystemHelpers.exists(url) }

    func testCopyThenUndoTrashesTheCopy() async {
        model.transfer([source.appendingPathComponent("a.txt")], kind: .copy, to: target)
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertTrue(exists(target.appendingPathComponent("a.txt")))
        XCTAssertTrue(exists(source.appendingPathComponent("a.txt")))
        XCTAssertEqual(UndoStack.shared.topName, "Copy")

        UndoStack.shared.undo()
        XCTAssertFalse(exists(target.appendingPathComponent("a.txt")))
    }

    func testReplaceSendsExistingToTrashAndUndoRestoresIt() async throws {
        try Data("old".utf8).write(to: target.appendingPathComponent("a.txt"))
        model.transfer([source.appendingPathComponent("a.txt")], kind: .copy, to: target,
                       policy: .always(.replace))
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "new")
        XCTAssertNil(model.operationError)

        UndoStack.shared.undo()
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "old")
    }

    func testSkipLeavesExistingAlone() async throws {
        try Data("old".utf8).write(to: target.appendingPathComponent("a.txt"))
        model.transfer([source.appendingPathComponent("a.txt")], kind: .move, to: target,
                       forceMove: true, policy: .always(.skip))
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "old")
        XCTAssertTrue(exists(source.appendingPathComponent("a.txt")), "skipped source must stay")
        XCTAssertFalse(UndoStack.shared.canUndo, "nothing changed, nothing to undo")
    }

    func testMergeFoldersMovesChildrenAndRemovesEmptiedSource() async throws {
        let folder = source.appendingPathComponent("pics")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: folder.appendingPathComponent("one.jpg"))
        try Data("2".utf8).write(to: folder.appendingPathComponent("two.jpg"))
        let existing = target.appendingPathComponent("pics")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existing.appendingPathComponent("two.jpg"))
        try Data("3".utf8).write(to: existing.appendingPathComponent("three.jpg"))

        // Merge the folders, keep both copies of the clashing file.
        model.transfer([folder], kind: .move, to: target, forceMove: true, policy: .always(.merge))
        await FileOperationQueue.shared.waitUntilIdle()

        XCTAssertTrue(exists(existing.appendingPathComponent("one.jpg")))
        XCTAssertTrue(exists(existing.appendingPathComponent("three.jpg")))
        // .merge on a file-vs-file conflict behaves like .replace.
        XCTAssertEqual(read(existing.appendingPathComponent("two.jpg")), "2")
        XCTAssertFalse(exists(folder), "emptied source folder is removed")

        UndoStack.shared.undo()
        XCTAssertTrue(exists(folder.appendingPathComponent("one.jpg")))
        XCTAssertEqual(read(existing.appendingPathComponent("two.jpg")), "old")
    }

    func testAskPolicyPublishesConflictAndApplyToAllCoversTheRest() async throws {
        try Data("b".utf8).write(to: source.appendingPathComponent("b.txt"))
        try Data("old a".utf8).write(to: target.appendingPathComponent("a.txt"))
        try Data("old b".utf8).write(to: target.appendingPathComponent("b.txt"))

        model.transfer(
            [source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt")],
            kind: .copy, to: target)  // default policy: .ask

        let queue = FileOperationQueue.shared
        for _ in 0..<200 where queue.pendingConflict == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let conflict = try XCTUnwrap(queue.pendingConflict)
        XCTAssertEqual(conflict.destination.lastPathComponent, "a.txt")
        XCTAssertFalse(conflict.bothDirectories)
        XCTAssertEqual(conflict.sourceSize, 3)

        queue.resolvePendingConflict(.keepBoth, applyToAll: true)
        await queue.waitUntilIdle()
        XCTAssertNil(queue.pendingConflict, "apply-to-all must not ask again for b.txt")
        XCTAssertTrue(exists(target.appendingPathComponent("a copy.txt")))
        XCTAssertTrue(exists(target.appendingPathComponent("b copy.txt")))
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "old a")
    }

    func testCancelFromConflictDialogStopsTheOperation() async throws {
        try Data("b".utf8).write(to: source.appendingPathComponent("b.txt"))
        try Data("old a".utf8).write(to: target.appendingPathComponent("a.txt"))
        model.transfer(
            [source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt")],
            kind: .copy, to: target)

        let queue = FileOperationQueue.shared
        for _ in 0..<200 where queue.pendingConflict == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(queue.pendingConflict)
        queue.cancel()
        await queue.waitUntilIdle()
        XCTAssertFalse(exists(target.appendingPathComponent("b.txt")), "nothing after the cancel point")
        XCTAssertNil(queue.progress)
    }

    func testCopyIntoOwnFolderDuplicates() async {
        model.transfer([source.appendingPathComponent("a.txt")], kind: .copy, to: source)
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertTrue(exists(source.appendingPathComponent("a copy.txt")))
    }

    func testMeasureCountsFilesAndBytes() throws {
        let folder = source.appendingPathComponent("tree/inner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("x.bin"))
        try Data(repeating: 1, count: 50).write(to: source.appendingPathComponent("tree/y.bin"))
        let measured = TransferWorker.measure(source.appendingPathComponent("tree"))
        XCTAssertEqual(measured.bytes, 150)
        XCTAssertEqual(measured.items, 4)  // tree, inner, x.bin, y.bin
    }
}

// MARK: - Panes & session

@MainActor
final class PaneTests: XCTestCase {
    var root: URL!
    var left: URL!
    var right: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerPanes-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompareDirectoriesMarksMissingNewerAndDifferentSize() throws {
        let fm = FileManager.default
        let old = Date(timeIntervalSinceNow: -3600)
        // same: identical date and size
        try Data("same".utf8).write(to: left.appendingPathComponent("same.txt"))
        try Data("same".utf8).write(to: right.appendingPathComponent("same.txt"))
        for side in [left!, right!] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: side.appendingPathComponent("same.txt").path)
        }
        // onlyLeft / onlyRight
        try Data("l".utf8).write(to: left.appendingPathComponent("onlyLeft.txt"))
        try Data("r".utf8).write(to: right.appendingPathComponent("onlyRight.txt"))
        // newer on the left
        try Data("v2".utf8).write(to: left.appendingPathComponent("newer.txt"))
        try Data("v1".utf8).write(to: right.appendingPathComponent("newer.txt"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: right.appendingPathComponent("newer.txt").path)
        // same date, different size → both
        try Data("short".utf8).write(to: left.appendingPathComponent("size.txt"))
        try Data("much longer".utf8).write(to: right.appendingPathComponent("size.txt"))
        for side in [left!, right!] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: side.appendingPathComponent("size.txt").path)
        }

        let tab = TabState(directory: left)
        tab.toggleDualPane()
        tab.secondary!.navigate(to: right)
        tab.activePane = .primary

        let marked = tab.compareDirectories()
        XCTAssertEqual(marked, 5)
        let leftNames = tab.primary.filteredItems.filter { tab.primary.selection.contains($0.id) }.map(\.name)
        let rightNames = tab.secondary!.filteredItems.filter { tab.secondary!.selection.contains($0.id) }.map(\.name)
        XCTAssertEqual(leftNames, ["newer.txt", "onlyLeft.txt", "size.txt"])
        XCTAssertEqual(rightNames, ["onlyRight.txt", "size.txt"])
    }

    func testSwapMirrorAndAdopt() {
        let tab = TabState(directory: left)
        tab.toggleDualPane()
        tab.secondary!.navigate(to: right)
        tab.activePane = .primary
        XCTAssertEqual(tab.otherModel?.currentDirectory.lastPathComponent, "right")

        tab.swapPanes()
        XCTAssertEqual(tab.primary.currentDirectory.lastPathComponent, "right")
        XCTAssertEqual(tab.activeModel.currentDirectory.lastPathComponent, "left", "active folder stays active")

        tab.mirrorToOtherPane()
        XCTAssertEqual(tab.otherModel?.currentDirectory.lastPathComponent, "left")

        tab.otherModel!.navigate(to: right)
        tab.adoptOtherPanePath()
        XCTAssertEqual(tab.activeModel.currentDirectory.lastPathComponent, "right")
    }

    func testSessionRestore() {
        let state = WindowState()
        state.newTab()
        state.activeModel.navigate(to: left)
        state.selectedTab!.toggleDualPane()
        state.activeModel.navigate(to: right)

        let snapshot = state.sessionSnapshot
        XCTAssertEqual(snapshot.tabs.count, 2)
        XCTAssertEqual(snapshot.selectedIndex, 1)

        let restored = WindowState(session: snapshot)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selectedTab?.primary.currentDirectory.lastPathComponent, "left")
        XCTAssertEqual(restored.selectedTab?.secondary?.currentDirectory.lastPathComponent, "right")
        XCTAssertEqual(restored.selectedTab?.activePane, .secondary)
        XCTAssertEqual(restored.sessionSnapshot, snapshot)
    }

    func testRequestTransferTargetsOtherPane() throws {
        try Data("x".utf8).write(to: left.appendingPathComponent("a.txt"))
        let state = WindowState()
        state.activeModel.navigate(to: left)
        state.selectedTab!.toggleDualPane()
        state.activeModel.navigate(to: right)
        state.selectedTab!.activePane = .primary
        state.activeModel.selectAll()

        state.requestTransfer(.copy)
        let request = try XCTUnwrap(state.transferRequest)
        XCTAssertEqual(request.kind, .copy)
        XCTAssertEqual(request.items.map(\.name), ["a.txt"])
        XCTAssertEqual(request.suggestedDestination.lastPathComponent, "right")
    }
}

@MainActor
final class FavoritesInsertTests: XCTestCase {
    func testInsertAcceptsOnlyFoldersAtPosition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileExplorerFav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("file.txt"))

        let store = FavoritesStore()
        let saved = store.urls
        defer { for url in store.urls { store.remove(url) }; for url in saved { store.add(url) } }
        for url in saved { store.remove(url) }

        store.add(root.appendingPathComponent("a"))
        store.add(root.appendingPathComponent("c"))
        store.insert([root.appendingPathComponent("file.txt"), root.appendingPathComponent("b")], at: 1)
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["a", "b", "c"], "files are ignored, folders land at the index")

        store.insert(root.appendingPathComponent("a"), at: 0)
        XCTAssertEqual(store.urls.count, 3, "duplicates are ignored")
    }
}
