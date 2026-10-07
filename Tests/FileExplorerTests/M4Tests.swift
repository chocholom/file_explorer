import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import FileExplorer

final class BatchRenamerTests: XCTestCase {
    func testFindReplacePreservesExtension() {
        let result = BatchRenamer.apply(
            .findReplace(find: "IMG", replace: "Holiday"),
            to: ["IMG_001.jpg", "IMG_002.jpg", "other.png"])
        XCTAssertEqual(result, ["Holiday_001.jpg", "Holiday_002.jpg", "other.png"])
    }

    func testNumbering() {
        let result = BatchRenamer.apply(
            .numbering(base: "Photo", start: 7, digits: 3),
            to: ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(result, ["Photo 007.jpg", "Photo 008.jpg", "Photo 009.jpg"])
    }

    func testCaseChange() {
        XCTAssertEqual(
            BatchRenamer.apply(.caseChange(.uppercase), to: ["report.pdf"]), ["REPORT.pdf"])
        XCTAssertEqual(
            BatchRenamer.apply(.caseChange(.lowercase), to: ["Report Draft.TXT"]),
            ["report draft.TXT"])
        XCTAssertEqual(
            BatchRenamer.apply(.caseChange(.titleCase), to: ["annual report.pdf"]),
            ["Annual Report.pdf"])
    }
}

final class CustomFilterParsingTests: XCTestCase {
    func testParseExtensions() {
        XCTAssertEqual(
            CustomFilter.parseExtensions("fbx, obj, .blend  GLB"),
            ["fbx", "obj", "blend", "glb"])
        XCTAssertEqual(CustomFilter.parseExtensions(""), [])
    }
}

@MainActor
final class OperationsUndoTests: XCTestCase {
    var fixtureDir: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        UndoStack.shared.clear()
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerUndoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixtureDir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try Data("x".utf8).write(to: fixtureDir.appendingPathComponent("a.txt"))
        model = DirectoryViewModel(directory: fixtureDir)
    }

    override func tearDown() async throws {
        UndoStack.shared.clear()
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: fixtureDir.appendingPathComponent(relative).path)
    }

    func testUndoRename() {
        model.rename(model.allItems.first { $0.name == "a.txt" }!, to: "b.txt")
        XCTAssertTrue(exists("b.txt"))
        XCTAssertEqual(UndoStack.shared.topName, "Rename")

        UndoStack.shared.undo()
        XCTAssertTrue(exists("a.txt"))
        XCTAssertFalse(exists("b.txt"))
        XCTAssertFalse(UndoStack.shared.canUndo)
    }

    func testUndoTrash() {
        model.trash([model.allItems.first { $0.name == "a.txt" }!])
        XCTAssertFalse(exists("a.txt"))

        UndoStack.shared.undo()
        XCTAssertTrue(exists("a.txt"))
    }

    func testUndoMove() async {
        model.moveOrCopy([fixtureDir.appendingPathComponent("a.txt")],
                         into: fixtureDir.appendingPathComponent("sub"))
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertTrue(exists("sub/a.txt"))
        XCTAssertFalse(exists("a.txt"))

        UndoStack.shared.undo()
        XCTAssertTrue(exists("a.txt"))
        XCTAssertFalse(exists("sub/a.txt"))
    }

    func testUndoDuplicate() {
        model.duplicate([model.allItems.first { $0.name == "a.txt" }!])
        XCTAssertTrue(exists("a copy.txt"))

        UndoStack.shared.undo()
        XCTAssertFalse(exists("a copy.txt"))
        XCTAssertTrue(exists("a.txt"))
    }

    func testForceMoveActsLikeCutPaste() async {
        // forceMove is the cut-paste path (moves even where a plain drop would copy).
        model.moveOrCopy([fixtureDir.appendingPathComponent("a.txt")],
                         into: fixtureDir.appendingPathComponent("sub"),
                         forceMove: true)
        await FileOperationQueue.shared.waitUntilIdle()
        XCTAssertTrue(exists("sub/a.txt"))
        XCTAssertFalse(exists("a.txt"))
    }

    func testBatchRenameWithSwappedNamesAndUndo() throws {
        try Data("x".utf8).write(to: fixtureDir.appendingPathComponent("b.txt"))
        model.reload()
        let items = model.allItems.filter { !$0.isDirectory }.sorted { $0.name < $1.name }

        // Numbering renames a.txt→File 001.txt, b.txt→File 002.txt.
        model.batchRename(items, mode: .numbering(base: "File", start: 1, digits: 3))
        XCTAssertTrue(exists("File 001.txt"))
        XCTAssertTrue(exists("File 002.txt"))
        XCTAssertFalse(exists("a.txt"))

        UndoStack.shared.undo()
        XCTAssertTrue(exists("a.txt"))
        XCTAssertTrue(exists("b.txt"))
    }
}

@MainActor
final class RecursiveSearchTests: XCTestCase {
    var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerSearchTests-\(UUID().uuidString)")
        let deep = fixtureDir.appendingPathComponent("level1/level2")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fixtureDir.appendingPathComponent("target-top.txt"))
        try Data("x".utf8).write(to: deep.appendingPathComponent("target-deep.txt"))
        try Data("x".utf8).write(to: deep.appendingPathComponent("unrelated.txt"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    func testRecursiveSearchFindsBuriedFiles() async throws {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.searchRecursively = true
        model.searchText = "target"

        // Debounce (250 ms) + walk; poll instead of a fixed sleep so a busy CI box can't flake it.
        for _ in 0..<500 where model.searchResults == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let names = model.filteredItems.map(\.name).sorted()
        XCTAssertEqual(names, ["target-deep.txt", "target-top.txt"])
        let deepItem = model.filteredItems.first { $0.name == "target-deep.txt" }
        XCTAssertEqual(deepItem?.searchPath, "level1/level2")
    }

    func testPlainSearchStaysShallow() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.searchText = "target"
        XCTAssertEqual(model.filteredItems.map(\.name), ["target-top.txt"])
    }
}

@MainActor
final class ConvertAndCompressTests: XCTestCase {
    var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

        // Tiny 2×2 PNG via ImageIO.
        let pngURL = fixtureDir.appendingPathComponent("tiny.png")
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = context.makeImage()!
        let sink = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        CGImageDestinationFinalize(sink)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    func testConvertPNGToJPG() throws {
        let source = fixtureDir.appendingPathComponent("tiny.png")
        let destination = fixtureDir.appendingPathComponent("tiny.jpg")
        let output = try ImageConverter.convert(source, to: .jpg, destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let converted = CGImageSourceCreateWithURL(output as CFURL, nil)
        XCTAssertEqual(
            CGImageSourceGetType(converted!) as String?, UTType.jpeg.identifier)
    }

    func testCompressCreatesZip() throws {
        let zip = fixtureDir.appendingPathComponent("out.zip")
        try Archiver.compress([fixtureDir.appendingPathComponent("tiny.png")], into: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testFolderSizeComputation() throws {
        try Data(repeating: 0, count: 1000)
            .write(to: fixtureDir.appendingPathComponent("k.bin"))
        let total = FolderSizeStore.computeSize(of: fixtureDir)
        XCTAssertGreaterThanOrEqual(total, 1000)
    }
}

@MainActor
final class GridNavigationTests: XCTestCase {
    var fixtureDir: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerGridNavTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        for index in 1...6 {
            try Data("x".utf8).write(to: fixtureDir.appendingPathComponent("f\(index).txt"))
        }
        model = DirectoryViewModel(directory: fixtureDir)
        model.gridColumnCount = 3
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    func testArrowNavigation() {
        let items = model.filteredItems

        XCTAssertTrue(model.moveGridSelection(keyCode: 124))  // → selects first
        XCTAssertEqual(model.selection, [items[0].id])

        XCTAssertTrue(model.moveGridSelection(keyCode: 124))  // → second
        XCTAssertEqual(model.selection, [items[1].id])

        XCTAssertTrue(model.moveGridSelection(keyCode: 125))  // ↓ one row (3 columns)
        XCTAssertEqual(model.selection, [items[4].id])

        XCTAssertTrue(model.moveGridSelection(keyCode: 126))  // ↑ back
        XCTAssertEqual(model.selection, [items[1].id])

        XCTAssertTrue(model.moveGridSelection(keyCode: 123))  // ← first
        XCTAssertEqual(model.selection, [items[0].id])

        // Out of range: handled but selection unchanged.
        XCTAssertTrue(model.moveGridSelection(keyCode: 123))
        XCTAssertEqual(model.selection, [items[0].id])
    }
}
