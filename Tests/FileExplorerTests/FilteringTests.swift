import XCTest

@testable import FileExplorer

@MainActor
final class FilteringTests: XCTestCase {
    var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerTests-\(UUID().uuidString)")
        let files = [
            "photo1.jpg", "photo2.jpg", "photo3.png", "shot.heic",
            "clip.mp4", "report.pdf", "notes.txt", "backup.zip", "mystery.xyz",
        ]
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixtureDir.appendingPathComponent("subfolder"), withIntermediateDirectories: false)
        for name in files {
            try Data("x".utf8).write(to: fixtureDir.appendingPathComponent(name))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    func testCategoryCounts() {
        let model = DirectoryViewModel(directory: fixtureDir)
        var counts: [FileTypeCategory: Int] = [:]
        for entry in model.categoryCounts { counts[entry.category] = entry.count }

        XCTAssertEqual(counts[.folders], 1)
        XCTAssertEqual(counts[.images], 4)
        XCTAssertEqual(counts[.video], 1)
        XCTAssertEqual(counts[.documents], 2)
        XCTAssertEqual(counts[.archives], 1)
        XCTAssertEqual(counts[.other], 1)
    }

    func testNoFilterShowsEverything() {
        let model = DirectoryViewModel(directory: fixtureDir)
        XCTAssertEqual(model.filteredItems.count, 10)
        // Folders sort first.
        XCTAssertEqual(model.filteredItems.first?.name, "subfolder")
    }

    func testCategoryFilter() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.toggleCategory(.images)
        XCTAssertEqual(
            model.filteredItems.map(\.name).sorted(),
            ["photo1.jpg", "photo2.jpg", "photo3.png", "shot.heic"])

        model.toggleCategory(.video)
        XCTAssertEqual(model.filteredItems.count, 5)
    }

    func testExtensionChipsAppearForSelectedCategory() {
        let model = DirectoryViewModel(directory: fixtureDir)
        XCTAssertTrue(model.extensionCounts.isEmpty)

        model.toggleCategory(.images)
        // Sorted by count desc, then name: jpg (2), heic (1), png (1).
        XCTAssertEqual(model.extensionCounts.map(\.ext), ["jpg", "heic", "png"])
        XCTAssertEqual(model.extensionCounts.map(\.count), [2, 1, 1])
    }

    func testExtensionNarrowsItsCategoryOnly() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.toggleCategory(.images)
        model.toggleCategory(.documents)
        model.toggleExtension("jpg")

        // jpg narrows Images; Documents stays whole.
        XCTAssertEqual(
            model.filteredItems.map(\.name).sorted(),
            ["notes.txt", "photo1.jpg", "photo2.jpg", "report.pdf"])
    }

    func testDeselectingCategoryDropsItsExtensions() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.toggleCategory(.images)
        model.toggleExtension("jpg")
        model.toggleCategory(.images)

        XCTAssertTrue(model.selectedExtensions.isEmpty)
        XCTAssertFalse(model.hasActiveFilters)
        XCTAssertEqual(model.filteredItems.count, 10)
    }

    func testClearFilters() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.toggleCategory(.archives)
        XCTAssertEqual(model.filteredItems.count, 1)
        model.clearFilters()
        XCTAssertEqual(model.filteredItems.count, 10)
    }

    func testNavigationHistory() {
        let model = DirectoryViewModel(directory: fixtureDir)
        let sub = fixtureDir.appendingPathComponent("subfolder")

        model.navigate(to: sub)
        XCTAssertEqual(model.currentDirectory.lastPathComponent, "subfolder")
        XCTAssertTrue(model.canGoBack)

        let resolvedFixturePath = fixtureDir.resolvingSymlinksInPath().standardizedFileURL.path

        model.goBack()
        XCTAssertEqual(model.currentDirectory.path, resolvedFixturePath)
        XCTAssertTrue(model.canGoForward)

        model.goForward()
        XCTAssertEqual(model.currentDirectory.lastPathComponent, "subfolder")

        model.goUp()
        XCTAssertEqual(model.currentDirectory.path, resolvedFixturePath)
    }

    func testFiltersResetOnNavigation() {
        let model = DirectoryViewModel(directory: fixtureDir)
        model.toggleCategory(.images)
        model.toggleExtension("jpg")
        model.navigate(to: fixtureDir.appendingPathComponent("subfolder"))

        XCTAssertFalse(model.hasActiveFilters)
    }

    func testSortBySizeAndDate() throws {
        let big = fixtureDir.appendingPathComponent("big.bin")
        try Data(repeating: 0, count: 10_000).write(to: big)

        let model = DirectoryViewModel(directory: fixtureDir)
        model.sortField = .size
        model.sortAscending = false
        // Folders first, then largest file.
        let names = model.filteredItems.map(\.name)
        XCTAssertEqual(names.first, "subfolder")
        XCTAssertEqual(names.dropFirst().first, "big.bin")
    }
}
