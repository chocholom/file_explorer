import XCTest

@testable import FileExplorer

@MainActor
final class SymlinkTests: XCTestCase {
    var fixtureDir: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        fixtureDir = fm.temporaryDirectory
            .appendingPathComponent("FileExplorerSymlinkTests-\(UUID().uuidString)")
        try fm.createDirectory(
            at: fixtureDir.appendingPathComponent("realdir"), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: fixtureDir.appendingPathComponent("realdir/inside.txt"))
        try Data("hello".utf8).write(to: fixtureDir.appendingPathComponent("real.txt"))

        try fm.createSymbolicLink(
            at: fixtureDir.appendingPathComponent("dirlink"),
            withDestinationURL: fixtureDir.appendingPathComponent("realdir"))
        try fm.createSymbolicLink(
            at: fixtureDir.appendingPathComponent("filelink.txt"),
            withDestinationURL: fixtureDir.appendingPathComponent("real.txt"))
        try fm.createSymbolicLink(
            at: fixtureDir.appendingPathComponent("broken"),
            withDestinationURL: fixtureDir.appendingPathComponent("does-not-exist"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func item(_ name: String, in model: DirectoryViewModel) -> FileItem? {
        model.allItems.first { $0.name == name }
    }

    func testSymlinkToDirectoryBehavesLikeFolder() {
        let model = DirectoryViewModel(directory: fixtureDir)
        let link = item("dirlink", in: model)

        XCTAssertNotNil(link)
        XCTAssertTrue(link!.isDirectory)
        XCTAssertTrue(link!.isSymlink)
        XCTAssertEqual(link!.category, .folders)
        XCTAssertEqual(link!.kindText, "Link → Folder")

        // Folders category counts both the real dir and the link.
        let folderCount = model.categoryCounts.first { $0.category == .folders }?.count
        XCTAssertEqual(folderCount, 2)
    }

    func testNavigatingIntoSymlinkedDirectoryListsTarget() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.navigate(to: fixtureDir.appendingPathComponent("dirlink"))

        XCTAssertEqual(model.allItems.map(\.name), ["inside.txt"])
        XCTAssertNil(model.loadError)
        // Finder-style: the path bar shows the resolved target, not the link.
        XCTAssertEqual(model.currentDirectory.lastPathComponent, "realdir")
    }

    func testSymlinkToFileUsesTargetSizeAndExtensionCategory() {
        let model = DirectoryViewModel(directory: fixtureDir)
        let link = item("filelink.txt", in: model)

        XCTAssertNotNil(link)
        XCTAssertFalse(link!.isDirectory)
        XCTAssertEqual(link!.category, .documents)
        XCTAssertEqual(link!.size, 5)  // target "hello", not the link inode
        XCTAssertEqual(link!.kindText, "Link")
    }

    func testBrokenSymlinkIsMarkedAndHarmless() {
        let model = DirectoryViewModel(directory: fixtureDir)
        let link = item("broken", in: model)

        XCTAssertNotNil(link)
        XCTAssertFalse(link!.isDirectory)
        XCTAssertTrue(link!.isBrokenSymlink)
        XCTAssertEqual(link!.kindText, "Broken Link")
        XCTAssertEqual(link!.category, .other)
    }
}
