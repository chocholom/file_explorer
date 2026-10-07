import XCTest

@testable import FileExplorer

@MainActor
final class AdvancedFilterTests: XCTestCase {
    var fixtureDir: URL!
    var model: DirectoryViewModel!

    override func setUp() async throws {
        let fm = FileManager.default
        fixtureDir = fm.temporaryDirectory
            .appendingPathComponent("FileExplorerM3Tests-\(UUID().uuidString)")
        try fm.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

        try Data("x".utf8).write(to: fixtureDir.appendingPathComponent("report.pdf"))
        try Data("x".utf8).write(to: fixtureDir.appendingPathComponent("Report Draft.txt"))
        try Data(repeating: 0, count: 2_000_000)
            .write(to: fixtureDir.appendingPathComponent("big.zip"))

        // An old file for date filtering.
        let oldFile = fixtureDir.appendingPathComponent("ancient.log")
        try Data("x".utf8).write(to: oldFile)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)],
            ofItemAtPath: oldFile.path)

        model = DirectoryViewModel(directory: fixtureDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    func testSearchIsCaseInsensitive() {
        model.searchText = "report"
        XCTAssertEqual(
            model.filteredItems.map(\.name).sorted(), ["Report Draft.txt", "report.pdf"])
        XCTAssertTrue(model.hasActiveFilters)
    }

    func testDateFilter() {
        model.dateFilter = .week
        XCTAssertFalse(model.filteredItems.map(\.name).contains("ancient.log"))

        model.dateFilter = .older
        XCTAssertEqual(model.filteredItems.map(\.name), ["ancient.log"])
    }

    func testSizeFilter() {
        model.sizeFilter = .oneTo100MB
        XCTAssertEqual(model.filteredItems.map(\.name), ["big.zip"])

        model.sizeFilter = .under1MB
        XCTAssertFalse(model.filteredItems.map(\.name).contains("big.zip"))
    }

    func testSearchCombinesWithCategoryFilter() {
        model.searchText = "report"
        model.toggleCategory(.documents)
        XCTAssertEqual(
            model.filteredItems.map(\.name).sorted(), ["Report Draft.txt", "report.pdf"])

        model.searchText = "draft"
        XCTAssertEqual(model.filteredItems.map(\.name), ["Report Draft.txt"])
    }

    func testClearFiltersResetsEverything() {
        model.searchText = "report"
        model.dateFilter = .week
        model.sizeFilter = .under1MB
        model.clearFilters()
        XCTAssertFalse(model.hasActiveFilters)
        XCTAssertEqual(model.filteredItems.count, 4)
    }

    func testFiltersResetOnNavigation() throws {
        try FileManager.default.createDirectory(
            at: fixtureDir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        model.reload()
        model.searchText = "report"
        model.dateFilter = .today
        model.navigate(to: fixtureDir.appendingPathComponent("sub"))
        XCTAssertFalse(model.hasActiveFilters)
    }
}

@MainActor
final class TabStateTests: XCTestCase {
    func testNewTabInheritsActiveDirectoryAndInsertsAfterCurrent() {
        let state = WindowState()
        let home = state.activeModel.currentDirectory

        state.newTab()
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.selectedTabID, state.tabs[1].id)
        XCTAssertEqual(state.activeModel.currentDirectory, home)
    }

    func testCloseTabSelectsNeighborAndKeepsLastTab() {
        let state = WindowState()
        state.newTab()
        state.newTab()
        XCTAssertEqual(state.tabs.count, 3)

        let middle = state.tabs[1]
        state.selectedTabID = middle.id
        state.closeTab(middle)
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.selectedTabID, state.tabs[1].id)

        // The last tab never closes.
        state.closeTab(state.tabs[0])
        state.closeTab(state.tabs[0])
        XCTAssertEqual(state.tabs.count, 1)
    }

    func testDualPaneToggleAndActiveModel() {
        let state = WindowState()
        let tab = state.selectedTab!
        XCTAssertFalse(tab.isDualPane)

        tab.toggleDualPane()
        XCTAssertTrue(tab.isDualPane)
        XCTAssertEqual(tab.activePane, .secondary)
        XCTAssertTrue(state.activeModel === tab.secondary)
        // Second pane opens at the first pane's location.
        XCTAssertEqual(tab.secondary!.currentDirectory, tab.primary.currentDirectory)

        tab.toggleDualPane()
        XCTAssertFalse(tab.isDualPane)
        XCTAssertTrue(state.activeModel === tab.primary)
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(Fuzzy.score(query: "xyz", candidate: "/downloads"))
        XCTAssertNil(Fuzzy.score(query: "", candidate: "/downloads"))
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(Fuzzy.score(query: "dow", candidate: "/downloads"))
        XCTAssertNotNil(Fuzzy.score(query: "dowwall", candidate: "/downloads/wallpapers"))
    }

    func testBoundaryMatchOutranksScatteredMatch() {
        // "dw" as component starts vs. scattered inside a single word.
        let boundary = Fuzzy.score(query: "dw", candidate: "/downloads/wallpapers")!
        let scattered = Fuzzy.score(query: "dw", candidate: "/sandwiches")!
        XCTAssertGreaterThan(boundary, scattered)
    }

    func testShorterPathWinsOnEqualMatch() {
        let short = Fuzzy.score(query: "doc", candidate: "/documents")!
        let long = Fuzzy.score(query: "doc", candidate: "/documents/very/deep/nested/folder")!
        XCTAssertGreaterThan(short, long)
    }
}
