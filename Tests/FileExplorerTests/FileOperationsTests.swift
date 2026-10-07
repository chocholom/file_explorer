import XCTest

@testable import FileExplorer

@MainActor
final class FileOperationsTests: XCTestCase {
    var fixtureDir: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixtureDir.appendingPathComponent("subfolder"), withIntermediateDirectories: false)
        for name in ["a.txt", "b.jpg"] {
            try Data("x".utf8).write(to: fixtureDir.appendingPathComponent(name))
        }
        model = DirectoryViewModel(directory: fixtureDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fixtureDir.appendingPathComponent(name).path)
    }

    private func item(_ name: String) -> FileItem? {
        model.allItems.first { $0.name == name }
    }

    func testNewFolderUsesUniqueNamesAndStartsRename() {
        let first = model.newFolder()
        XCTAssertEqual(first?.name, "untitled folder")
        XCTAssertEqual(model.renameTarget?.name, "untitled folder")
        XCTAssertEqual(model.selection, [first!.id])

        let second = model.newFolder()
        XCTAssertEqual(second?.name, "untitled folder 2")
        XCTAssertTrue(exists("untitled folder"))
        XCTAssertTrue(exists("untitled folder 2"))
    }

    func testRename() {
        model.rename(item("a.txt")!, to: "renamed.txt")
        XCTAssertNil(model.operationError)
        XCTAssertTrue(exists("renamed.txt"))
        XCTAssertFalse(exists("a.txt"))
        // Renamed item stays selected under its new URL.
        XCTAssertEqual(model.selectedItems.map(\.name), ["renamed.txt"])
    }

    func testRenameCollisionReportsError() {
        model.rename(item("a.txt")!, to: "b.jpg")
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(exists("a.txt"))
    }

    func testRenameRejectsSlash() {
        model.rename(item("a.txt")!, to: "bad/name")
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(exists("a.txt"))
    }

    func testDuplicateUsesFinderStyleNames() {
        let target = item("a.txt")!
        model.duplicate([target])
        model.duplicate([target])
        XCTAssertTrue(exists("a copy.txt"))
        XCTAssertTrue(exists("a copy 2.txt"))
        XCTAssertNil(model.operationError)
    }

    func testTrashRemovesItemsAndSelection() {
        let target = item("a.txt")!
        model.selection = [target.id]
        model.trashSelection()
        XCTAssertFalse(exists("a.txt"))
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.operationError)
    }

    func testMoveIntoSubfolder() async {
        let source = fixtureDir.appendingPathComponent("a.txt")
        let subfolder = fixtureDir.appendingPathComponent("subfolder")
        model.moveOrCopy([source], into: subfolder)
        await FileOperationQueue.shared.waitUntilIdle()

        XCTAssertFalse(exists("a.txt"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: subfolder.appendingPathComponent("a.txt").path))
        XCTAssertNil(model.operationError)
    }

    func testMoveIntoSameFolderIsNoOp() async {
        model.moveOrCopy([fixtureDir.appendingPathComponent("a.txt")], into: fixtureDir)
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertTrue(exists("a.txt"))
        XCTAssertFalse(exists("a copy.txt"))
        XCTAssertNil(model.operationError)
    }

    func testMoveFolderIntoItselfIsRejected() async {
        let subfolder = fixtureDir.appendingPathComponent("subfolder")
        model.moveOrCopy([subfolder], into: subfolder)
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertTrue(exists("subfolder"))

        let nested = subfolder.appendingPathComponent("nested")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        model.moveOrCopy([subfolder], into: nested)
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(exists("subfolder"))
    }

    func testMoveCollisionKeepBothGetsUniqueName() async throws {
        let subfolder = fixtureDir.appendingPathComponent("subfolder")
        try Data("y".utf8).write(to: subfolder.appendingPathComponent("a.txt"))
        model.moveOrCopy([fixtureDir.appendingPathComponent("a.txt")], into: subfolder,
                         policy: .always(.keepBoth))
        await FileOperationQueue.shared.waitUntilIdle()

        XCTAssertFalse(exists("a.txt"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: subfolder.appendingPathComponent("a copy.txt").path))
    }
}
