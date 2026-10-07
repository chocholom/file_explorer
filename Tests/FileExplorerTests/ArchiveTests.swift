import XCTest

@testable import FileExplorer

/// Builds a small folder tree and zips it with /usr/bin/zip (what the app itself uses).
private enum ArchiveFixture {
    static func makeTree(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs/notes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("top".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try Data("photo bytes".utf8).write(to: root.appendingPathComponent("docs/Žluťoučký kůň.jpg"))
        try Data("deep".utf8).write(to: root.appendingPathComponent("docs/notes/todo list.md"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".secret"))
    }

    static func zip(_ tree: URL, to archive: URL, directoryEntries: Bool = true) throws {
        var arguments = ["-r", "-q", archive.path, "."]
        if !directoryEntries { arguments.insert("-D", at: 0) }
        _ = try SystemTar.run(URL(fileURLWithPath: "/usr/bin/zip"), arguments, currentDirectory: tree)
    }

    static func tarGz(_ tree: URL, to archive: URL) throws {
        _ = try SystemTar.run(SystemTar.executable, ["-czf", archive.path, "-C", tree.path, "."])
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timed out waiting"); return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: - Readers

final class ZipReaderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FileExplorerZip-\(UUID().uuidString)")
        try ArchiveFixture.makeTree(at: root.appendingPathComponent("tree"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParsesEntriesNamesSizesDatesAndFolders() throws {
        let archive = root.appendingPathComponent("a.zip")
        try ArchiveFixture.zip(root.appendingPathComponent("tree"), to: archive)
        let entries = try ZipReader.entries(of: archive)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

        XCTAssertEqual(byPath["readme.txt"]?.size, 3)
        XCTAssertEqual(byPath["readme.txt"]?.isDirectory, false)
        XCTAssertEqual(byPath["docs/Žluťoučký kůň.jpg"]?.size, 11, "UTF-8 names survive")
        XCTAssertEqual(byPath["docs/notes/todo list.md"]?.size, 4)
        XCTAssertEqual(byPath["docs"]?.isDirectory, true)
        XCTAssertEqual(byPath["empty"]?.isDirectory, true)
        XCTAssertNil(byPath["."], "the '.' root entry is dropped")

        let onDisk = try root.appendingPathComponent("tree/readme.txt").resourceValues(forKeys: [.contentModificationDateKey])
        let delta = abs(byPath["readme.txt"]!.modified.timeIntervalSince(onDisk.contentModificationDate!))
        XCTAssertLessThan(delta, 3, "DOS timestamps have 2-second resolution")
    }

    func testIndexFillsImplicitFoldersAndListsChildren() throws {
        let archive = root.appendingPathComponent("flat.zip")
        try ArchiveFixture.zip(root.appendingPathComponent("tree"), to: archive, directoryEntries: false)
        let index = try ArchiveIndexCache.shared.index(for: archive)

        XCTAssertEqual(index.entry(at: "docs")?.isDirectory, true, "parent folders are synthesised")
        XCTAssertEqual(index.entry(at: "docs/notes")?.isDirectory, true)
        XCTAssertEqual(Set(index.children(of: "").map(\.name)), ["readme.txt", "docs", ".secret"],
                       "-D drops the empty folder; everything else is reachable")
        XCTAssertEqual(Set(index.children(of: "docs").map(\.name)), ["Žluťoučký kůň.jpg", "notes"])
        XCTAssertEqual(index.descendants(of: "docs").count, 3)
        XCTAssertEqual(index.fileCount, 4)
        XCTAssertTrue(index.exists("docs/notes/todo list.md"))

        // The cache is validated against the file: rewriting the archive invalidates it.
        XCTAssertNotNil(ArchiveIndexCache.shared.cached(for: archive))
        try ArchiveFixture.zip(root.appendingPathComponent("tree"), to: archive)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: archive.path)
        XCTAssertNil(ArchiveIndexCache.shared.cached(for: archive))
    }

    func testRejectsNonZip() throws {
        let bogus = root.appendingPathComponent("bogus.zip")
        try Data("definitely not a zip file".utf8).write(to: bogus)
        XCTAssertThrowsError(try ZipReader.entries(of: bogus))
    }
}

final class SystemTarTests: XCTestCase {
    func testParsesListingLines() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        let file = SystemTar.parseListingLine(
            "-rw-r--r--  0 mirek  staff    1234 Jul  7 12:34 dir/file name.txt", now: now)
        XCTAssertEqual(file?.path, "dir/file name.txt")
        XCTAssertEqual(file?.size, 1234)
        XCTAssertEqual(file?.isDirectory, false)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: file!.modified)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 7, 7, 12, 34])

        let old = SystemTar.parseListingLine("drwxr-xr-x  0 501    0           0 Oct  6  2024 dir/", now: now)
        XCTAssertEqual(old?.path, "dir")
        XCTAssertEqual(old?.isDirectory, true)
        XCTAssertEqual(Calendar.current.component(.year, from: old!.modified), 2024)

        let future = SystemTar.parseListingLine("-rw-r--r--  0 u g 1 Dec 24 10:00 x.bin", now: now)
        XCTAssertEqual(Calendar.current.component(.year, from: future!.modified), 2025, "a 'recent' date in the future belongs to last year")

        let link = SystemTar.parseListingLine("lrwxr-xr-x  0 u g 0 Oct  6 10:00 link -> target", now: now)
        XCTAssertEqual(link?.path, "link")
        XCTAssertNil(SystemTar.parseListingLine("garbage"))
    }

    func testListsAndExtractsTarGz() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileExplorerTar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try ArchiveFixture.makeTree(at: root.appendingPathComponent("tree"))
        let archive = root.appendingPathComponent("t.tgz")
        try ArchiveFixture.tarGz(root.appendingPathComponent("tree"), to: archive)

        XCTAssertEqual(ArchiveFormat.detect(archive), .libarchive)
        let index = try ArchiveIndexCache.shared.index(for: archive)
        XCTAssertEqual(index.entry(at: "docs/notes/todo list.md")?.size, 4)
        XCTAssertEqual(index.entry(at: "empty")?.isDirectory, true)

        let out = root.appendingPathComponent("out")
        try SystemTar.extract(["docs/notes"], from: archive, to: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("docs/notes/todo list.md"), encoding: .utf8), "deep")
        XCTAssertFalse(FileSystemHelpers.exists(out.appendingPathComponent("readme.txt")))
    }
}

final class ArchiveLocatorTests: XCTestCase {
    func testLocatesArchivesAndVirtualPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileExplorerLoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("a.zip")
        try Data().write(to: archive)
        try Data().write(to: root.appendingPathComponent("plain.txt"))

        XCTAssertNil(ArchiveLocator.locate(root.appendingPathComponent("real")))
        XCTAssertNil(ArchiveLocator.locate(root.appendingPathComponent("plain.txt")))
        XCTAssertNil(ArchiveLocator.locate(root.appendingPathComponent("plain.txt/inside")))
        XCTAssertEqual(ArchiveLocator.locate(archive), ArchivePath(archiveURL: archive, path: ""))
        let inner = ArchiveLocator.locate(archive.appendingPathComponent("docs/notes"))
        XCTAssertEqual(inner?.path, "docs/notes")
        XCTAssertEqual(inner?.virtualURL.path, archive.appendingPathComponent("docs/notes").path)
        XCTAssertEqual(inner?.appending("x.txt").path, "docs/notes/x.txt")
        XCTAssertEqual(DirectoryViewModel.archiveStem("photos.tar.gz"), "photos")
        XCTAssertEqual(DirectoryViewModel.archiveStem("Backup.zip"), "Backup")
    }
}

// MARK: - Browsing & writing through the view model

@MainActor
final class ArchiveBrowsingTests: XCTestCase {
    var root: URL!
    var archive: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        UndoStack.shared.clear()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FileExplorerArchiveVM-\(UUID().uuidString)")
        try ArchiveFixture.makeTree(at: root.appendingPathComponent("tree"))
        archive = root.appendingPathComponent("Backup.zip")
        try ArchiveFixture.zip(root.appendingPathComponent("tree"), to: archive)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
        model = DirectoryViewModel(directory: root)
    }

    override func tearDown() async throws {
        UndoStack.shared.clear()
        try? FileManager.default.removeItem(at: root)
    }

    private func enterArchive(_ path: String = "") async throws {
        model.navigate(to: path.isEmpty ? archive : archive.appendingPathComponent(path))
        try await waitUntil { self.model.archiveActivity == nil && (!self.model.allItems.isEmpty || self.model.loadError != nil) }
        XCTAssertNil(model.loadError)
    }

    private func settle() async throws {
        try await waitUntil { self.model.archiveActivity == nil }
        await FileOperationQueue.shared.waitUntilIdle()
        try await waitUntil { self.model.archiveActivity == nil }
    }

    private func names() -> [String] { model.filteredItems.map(\.name) }

    func testArchiveFileIsEnterableAndListsLikeAFolder() async throws {
        let item = model.allItems.first { $0.name == "Backup.zip" }!
        XCTAssertTrue(item.isArchive)
        XCTAssertEqual(item.kindText, "ZIP Archive")

        try await enterArchive()
        XCTAssertTrue(model.isInsideArchive)
        XCTAssertTrue(model.isArchiveWritable)
        XCTAssertEqual(names(), ["docs", "empty", "readme.txt"], "folders first, hidden .secret filtered out")
        XCTAssertTrue(model.allItems.allSatisfy(\.isArchiveEntry))

        model.showHiddenFiles = true
        try await waitUntil { self.model.allItems.count == 4 }
        XCTAssertTrue(names().contains(".secret"))
        model.showHiddenFiles = false

        try await enterArchive("docs/notes")
        XCTAssertEqual(names(), ["todo list.md"])
        XCTAssertEqual(model.currentDirectory.lastPathComponent, "notes")

        // Backspace semantics: up to docs, then to the archive root, then out, selecting the archive.
        model.goUp()
        try await waitUntil { self.model.currentDirectory.lastPathComponent == "docs" && !self.model.allItems.isEmpty }
        XCTAssertEqual(model.selectedItems.map(\.name), ["notes"])
        model.goUp()
        model.goUp()
        try await waitUntil { !self.model.isInsideArchive }
        XCTAssertEqual(model.currentDirectory.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.selectedItems.map(\.name), ["Backup.zip"])
    }

    func testRecursiveSearchInsideArchive() async throws {
        try await enterArchive()
        model.searchRecursively = true
        model.searchText = "todo"
        XCTAssertEqual(names(), ["todo list.md"])
        XCTAssertEqual(model.filteredItems.first?.searchPath, "docs/notes")
    }

    func testSnapshotRestoresArchiveLocation() async throws {
        try await enterArchive("docs")
        let restored = DirectoryViewModel(snapshot: model.snapshot)
        XCTAssertEqual(restored.currentDirectory.path, archive.appendingPathComponent("docs").path)
        XCTAssertTrue(restored.isInsideArchive)
    }

    func testCopyOutOfArchive() async throws {
        try await enterArchive("docs")
        let target = root.appendingPathComponent("target")
        model.transfer(model.filteredItems.map(\.url), kind: .copy, to: target)
        try await settle()
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("notes/todo list.md"), encoding: .utf8), "deep")
        XCTAssertTrue(FileSystemHelpers.exists(target.appendingPathComponent("Žluťoučký kůň.jpg")))
        XCTAssertEqual(UndoStack.shared.topName, "Copy")
        UndoStack.shared.undo()
        XCTAssertFalse(FileSystemHelpers.exists(target.appendingPathComponent("notes")))
    }

    func testMaterializeForQuickLookAndOpen() async throws {
        try await enterArchive()
        let readme = model.allItems.first { $0.name == "readme.txt" }!
        model.quickLook(readme)
        try await waitUntil { self.model.quickLookItem != nil }
        let url = try XCTUnwrap(model.quickLookItem)
        XCTAssertTrue(url.path.hasPrefix(ArchiveCache.shared.root.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "top")
        XCTAssertEqual(ArchiveCache.shared.materialized(readme.archiveEntry!), url)
        XCTAssertNotNil(readme.dragProvider().registeredTypeIdentifiers.first)
    }

    func testCopyIntoArchiveWithConflictPolicies() async throws {
        try Data("new readme".utf8).write(to: root.appendingPathComponent("target/readme.txt"))
        try Data("extra".utf8).write(to: root.appendingPathComponent("target/extra.txt"))
        try await enterArchive()

        // Keep both: the clashing readme becomes "readme copy.txt".
        model.transfer(
            [root.appendingPathComponent("target/readme.txt"), root.appendingPathComponent("target/extra.txt")],
            kind: .copy, to: archive, policy: .always(.keepBoth))
        try await settle()
        try await waitUntil { self.names().contains("extra.txt") }
        XCTAssertEqual(names(), ["docs", "empty", "extra.txt", "readme copy.txt", "readme.txt"])

        // Replace: content inside the archive changes.
        model.transfer([root.appendingPathComponent("target/readme.txt")], kind: .copy, to: archive, policy: .always(.replace))
        try await settle()
        let readme = ArchivePath(archiveURL: archive, path: "readme.txt")
        ArchiveIndexCache.shared.invalidate(archive)
        XCTAssertEqual(try String(contentsOf: ArchiveCache.shared.materialize(readme), encoding: .utf8), "new readme")

        // Undo of the first add removes both entries again.
        UndoStack.shared.undo()  // replace
        UndoStack.shared.undo()  // keep-both add
        try await waitUntil { !self.names().contains("extra.txt") }
        XCTAssertFalse(names().contains("readme copy.txt"))
    }

    func testCopyIntoSubfolderOfArchiveAndDropOntoArchiveFile() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("target/added.txt"))
        try await enterArchive("docs/notes")
        model.transfer([root.appendingPathComponent("target/added.txt")], kind: .copy, to: model.currentDirectory)
        try await settle()
        try await waitUntil { self.names().contains("added.txt") }
        XCTAssertEqual(names(), ["added.txt", "todo list.md"])

        // Dropping a file onto the archive *file* in a normal folder copies into its root.
        model.navigate(to: root)
        model.moveOrCopy([root.appendingPathComponent("target/added.txt")], into: archive, policy: .always(.replace))
        try await settle()
        let index = try ArchiveIndexCache.shared.index(for: archive)
        XCTAssertTrue(index.exists("added.txt"))
        XCTAssertTrue(index.exists("docs/notes/added.txt"))
    }

    func testMoveIntoArchiveTrashesSourceAndUndoRestores() async throws {
        let source = root.appendingPathComponent("target/moved.txt")
        try Data("m".utf8).write(to: source)
        try await enterArchive()
        model.transfer([source], kind: .move, to: archive, forceMove: true)
        try await settle()
        try await waitUntil { self.names().contains("moved.txt") }
        XCTAssertFalse(FileSystemHelpers.exists(source), "moved source goes to the Trash")

        UndoStack.shared.undo()
        try await waitUntil { !self.names().contains("moved.txt") }
        XCTAssertTrue(FileSystemHelpers.exists(source), "undo restores the source from the Trash")
    }

    func testMoveOutOfArchiveRemovesEntry() async throws {
        try await enterArchive()
        let readme = model.allItems.first { $0.name == "readme.txt" }!
        model.transfer([readme.url], kind: .move, to: root.appendingPathComponent("target"), forceMove: true)
        try await settle()
        try await waitUntil { !self.names().contains("readme.txt") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/readme.txt"), encoding: .utf8), "top")
    }

    func testDeleteNewFolderAndRenameInsideArchive() async throws {
        try await enterArchive()

        // Delete goes through the permanent-delete confirmation (archives have no Trash).
        let empty = model.allItems.first { $0.name == "empty" }!
        model.trash([empty])
        XCTAssertEqual(model.pendingPermanentDelete?.map(\.name), ["empty"])
        model.confirmPermanentDelete()
        try await settle()
        try await waitUntil { !self.names().contains("empty") }

        // New folder appears and gets selected for renaming.
        model.newFolder()
        try await settle()
        try await waitUntil { self.names().contains("untitled folder") }
        XCTAssertEqual(model.selectedItems.map(\.name), ["untitled folder"])
        XCTAssertEqual(model.renameTarget?.name, "untitled folder")

        model.rename(model.renameTarget!, to: "Renamed")
        try await settle()
        try await waitUntil { self.names().contains("Renamed") }
        XCTAssertFalse(names().contains("untitled folder"))
        XCTAssertEqual(model.selectedItems.map(\.name), ["Renamed"])

        // Deleting a folder removes everything below it.
        let docs = model.allItems.first { $0.name == "docs" }!
        model.requestPermanentDelete([docs])
        model.confirmPermanentDelete()
        try await settle()
        try await waitUntil { !self.names().contains("docs") }
        let index = try ArchiveIndexCache.shared.index(for: archive)
        XCTAssertFalse(index.exists("docs/notes/todo list.md"))
        XCTAssertEqual(index.fileCount, 2)  // readme.txt + .secret
    }

    func testReadOnlyArchiveRefusesWrites() async throws {
        let tgz = root.appendingPathComponent("ro.tgz")
        try ArchiveFixture.tarGz(root.appendingPathComponent("tree"), to: tgz)
        model.navigate(to: tgz)
        try await waitUntil { self.model.archiveActivity == nil && !self.model.allItems.isEmpty }
        XCTAssertTrue(model.isInsideArchive)
        XCTAssertFalse(model.isArchiveWritable)
        XCTAssertFalse(model.canModifyHere)

        model.transfer([root.appendingPathComponent("tree/readme.txt")], kind: .copy, to: tgz)
        XCTAssertNotNil(model.operationError)
        model.operationError = nil
        XCTAssertNil(model.newFolder())
        XCTAssertNotNil(model.operationError)

        // Reading still works: copy out.
        model.operationError = nil
        let readme = model.allItems.first { $0.name == "readme.txt" }!
        model.transfer([readme.url], kind: .copy, to: root.appendingPathComponent("target"))
        try await settle()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/readme.txt"), encoding: .utf8), "top")
    }

    func testExtractArchiveIntoFolder() async throws {
        let item = model.allItems.first { $0.name == "Backup.zip" }!
        model.extract(item, into: root.appendingPathComponent("target"))
        try await settle()
        let out = root.appendingPathComponent("target/Backup")
        try await waitUntil { FileSystemHelpers.exists(out.appendingPathComponent("docs/notes/todo list.md")) }
        XCTAssertTrue(FileSystemHelpers.exists(out.appendingPathComponent("readme.txt")))
        XCTAssertTrue(FileSystemHelpers.exists(out.appendingPathComponent(".secret")), "extraction includes hidden entries")
    }
}
