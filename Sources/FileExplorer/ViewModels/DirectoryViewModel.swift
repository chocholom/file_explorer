import Foundation
import Observation

@MainActor
@Observable
final class DirectoryViewModel {
    enum ViewMode: String, CaseIterable {
        case list = "List"
        case grid = "Grid"
    }

    enum SortField: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case date = "Date Modified"
        case kind = "Kind"
    }

    private(set) var currentDirectory: URL
    private(set) var allItems: [FileItem] = [] {
        didSet { refilter() }
    }
    /// The listing after search, filters and sorting. Cached: recomputed only when an
    /// input changes, not on every view render (the sort alone is O(n log n)).
    private(set) var filteredItems: [FileItem] = []
    private(set) var loadError: String?
    /// Free space on the current folder's volume, refreshed on every reload.
    private(set) var freeSpace: Int64?

    /// Non-nil while browsing inside an archive (the listing comes from `ArchiveIndexCache`).
    private(set) var archiveLocation: ArchivePath?
    /// Shown in the pane while an archive is being indexed, extracted or rewritten.
    var archiveActivity: String?
    /// After an archive write, select (and optionally rename) this item once the listing is back.
    var pendingSelection: (name: String, rename: Bool)?
    @ObservationIgnored private var indexingArchive: URL?

    var isInsideArchive: Bool { archiveLocation != nil }
    var isArchiveWritable: Bool { archiveLocation?.format.isWritable ?? false }
    /// Items can be created or changed here: a real folder, or a ZIP.
    var canModifyHere: Bool { archiveLocation == nil || isArchiveWritable }

    var selection = Set<FileItem.ID>()
    var renameTarget: FileItem?
    var infoTarget: FileItem?
    var batchRenameRequest: BatchRenameRequest?
    var pendingPermanentDelete: [FileItem]?
    var operationError: String?
    var quickLookItem: URL?

    var searchText = "" {
        didSet {
            scheduleRecursiveSearch()
            refilter()
        }
    }
    var searchRecursively = false {
        didSet {
            scheduleRecursiveSearch()
            refilter()
        }
    }
    private(set) var searchResults: [FileItem]? {
        didSet { refilter() }
    }
    private(set) var isSearching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var dateFilter: DateFilter = .any {
        didSet { refilter() }
    }
    var sizeFilter: SizeFilter = .any {
        didSet { refilter() }
    }
    var selectedCustomFilterIDs: Set<UUID> = [] {
        didSet { refilter() }
    }

    /// Column count estimate reported by the grid view; used for arrow-key navigation.
    var gridColumnCount = 1

    var selectedCategories: Set<FileTypeCategory> = [] {
        didSet { refilter() }
    }
    var selectedExtensions: Set<String> = [] {
        didSet { refilter() }
    }
    var viewMode: ViewMode = .list
    var sortField: SortField = .name {
        didSet { refilter() }
    }
    var sortAscending = true {
        didSet { refilter() }
    }
    var showHiddenFiles = false {
        didSet { reload() }
    }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var suppressRefilter = false

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        currentDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        reload()
        watch(currentDirectory)
    }

    /// Restores a pane saved by `SessionStore`; falls back to home if the folder is gone.
    convenience init(snapshot: PaneSnapshot) {
        let url = URL(fileURLWithPath: snapshot.path)
        let restorable = FileSystemHelpers.isDirectory(url) || ArchiveLocator.locate(url) != nil
        self.init(directory: restorable ? url : FileManager.default.homeDirectoryForCurrentUser)
        viewMode = ViewMode(rawValue: snapshot.viewMode) ?? .list
        sortField = SortField(rawValue: snapshot.sortField) ?? .name
        sortAscending = snapshot.sortAscending
        if snapshot.showHiddenFiles { showHiddenFiles = true }
    }

    var snapshot: PaneSnapshot {
        PaneSnapshot(
            path: currentDirectory.path,
            viewMode: viewMode.rawValue,
            sortField: sortField.rawValue,
            sortAscending: sortAscending,
            showHiddenFiles: showHiddenFiles)
    }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentDirectory.path != "/" }

    func navigate(to url: URL) {
        // Follow symlinks like Finder: enter the target and show its real path.
        // (contentsOfDirectory(at:) can't enumerate through a symlink URL anyway.)
        let destination = url.resolvingSymlinksInPath().standardizedFileURL
        guard destination.path != currentDirectory.path else { return }
        backStack.append(currentDirectory)
        forwardStack.removeAll()
        setDirectory(destination)
    }

    func goBack() {
        guard let url = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        setDirectory(url)
    }

    func goForward() {
        guard let url = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        setDirectory(url)
    }

    /// Goes to the parent and selects the folder we came from (Commander behaviour).
    func goUp() {
        guard canGoUp else { return }
        let child = currentDirectory
        navigate(to: currentDirectory.deletingLastPathComponent())
        if let item = allItems.first(where: { FileSystemHelpers.canonicalPath($0.url) == child.path }) {
            selection = [item.id]
        }
    }

    func goHome() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    private func setDirectory(_ url: URL) {
        suppressRefilter = true
        currentDirectory = url
        selectedCategories = []
        selectedExtensions = []
        selectedCustomFilterIDs = []
        selection = []
        searchText = ""
        dateFilter = .any
        sizeFilter = .any
        suppressRefilter = false
        reload()
        watch(url)
    }

    private func watch(_ url: URL) {
        if let location = ArchiveLocator.locate(url) {
            // Inside an archive: watch the archive file itself. zip rewrites it via
            // rename, which ends the watch, so reloadArchive() re-arms this.
            let archive = location.archiveURL
            watcher = DirectoryWatcher(url: archive) { [weak self] in
                ArchiveIndexCache.shared.invalidate(archive)
                self?.scheduleReload()
            }
            return
        }
        watcher = DirectoryWatcher(url: url) { [weak self] in
            self?.scheduleReload()
        }
    }

    // MARK: - Loading

    /// File-system events arrive in bursts (a batch rename fires one per file);
    /// coalesce them into a single reload.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        let fm = FileManager.default

        if let location = ArchiveLocator.locate(currentDirectory) {
            reloadArchive(location)
            return
        }
        archiveLocation = nil
        archiveActivity = nil

        // The folder was deleted, renamed or unmounted while we were looking at it:
        // climb to the nearest ancestor that still exists instead of showing an error.
        if !FileSystemHelpers.isDirectory(currentDirectory) {
            var ancestor = currentDirectory
            while ancestor.path != "/", !FileSystemHelpers.isDirectory(ancestor) {
                ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
            }
            if ancestor != currentDirectory {
                backStack.append(currentDirectory)
                setDirectory(ancestor)
                return
            }
        }

        // Prefetch every key FileItem reads so its resourceValues() calls hit the cache.
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHiddenFiles { options.insert(.skipsHiddenFiles) }

        do {
            let urls = try fm.contentsOfDirectory(
                at: currentDirectory, includingPropertiesForKeys: keys, options: options)
            allItems = urls.compactMap { FileItem(url: $0) }
            loadError = nil
        } catch {
            allItems = []
            loadError = error.localizedDescription
        }
        freeSpace = FileSystemHelpers.freeSpace(at: currentDirectory)
        pruneSelection()
    }

    /// Lists an archive folder from the cached index; builds the index off the main
    /// thread first if needed (tgz listings decompress the whole stream).
    private func reloadArchive(_ location: ArchivePath) {
        archiveLocation = location
        loadError = nil
        freeSpace = FileSystemHelpers.freeSpace(at: location.archiveURL.deletingLastPathComponent())

        if let index = ArchiveIndexCache.shared.cached(for: location.archiveURL) {
            indexingArchive = nil
            archiveActivity = nil
            var children = index.children(of: location.path)
            if !showHiddenFiles {
                children = children.filter { !$0.name.hasPrefix(".") && $0.name != "__MACOSX" }
            }
            allItems = children.map { FileItem(entry: $0, in: location.archiveURL) }
            pruneSelection()
            watch(currentDirectory)
            if let pending = pendingSelection {
                pendingSelection = nil
                if let item = allItems.first(where: { $0.name == pending.name }) {
                    selection = [item.id]
                    if pending.rename { renameTarget = item }
                }
            }
            return
        }

        let archive = location.archiveURL
        guard indexingArchive != archive else { return }  // already on it
        indexingArchive = archive
        archiveActivity = "Indexing “\(archive.lastPathComponent)”…"
        allItems = []
        Task.detached(priority: .userInitiated) {
            let result = Result { try ArchiveIndexCache.shared.index(for: archive) }
            await MainActor.run {
                guard self.indexingArchive == archive else { return }
                self.indexingArchive = nil
                self.archiveActivity = nil
                guard self.archiveLocation?.archiveURL == archive else { return }
                switch result {
                case .success:
                    self.reload()
                case .failure(let error):
                    self.loadError = error.localizedDescription
                }
            }
        }
    }

    /// Drop selection entries for items that no longer exist (moved, trashed, renamed
    /// externally). Recursive-search results aren't in allItems, so leave those alone.
    private func pruneSelection() {
        guard searchResults == nil else { return }
        let existing = Set(allItems.map(\.id))
        let pruned = selection.filter { existing.contains($0) }
        if pruned.count != selection.count { selection = pruned }
    }

    // MARK: - Filtering

    var hasActiveFilters: Bool {
        !selectedCategories.isEmpty || !selectedExtensions.isEmpty
            || !selectedCustomFilterIDs.isEmpty || !searchText.isEmpty
            || dateFilter != .any || sizeFilter != .any
    }

    /// Categories present in the current folder, in canonical order, with counts.
    var categoryCounts: [(category: FileTypeCategory, count: Int)] {
        var counts: [FileTypeCategory: Int] = [:]
        for item in allItems {
            counts[item.category, default: 0] += 1
        }
        return FileTypeCategory.allCases.compactMap { category in
            counts[category].map { (category, $0) }
        }
    }

    /// Extensions within the selected (non-folder) categories, most frequent first.
    var extensionCounts: [(ext: String, count: Int)] {
        let categories = selectedCategories.subtracting([.folders])
        guard !categories.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for item in allItems where categories.contains(item.category) && !item.ext.isEmpty {
            counts[item.ext, default: 0] += 1
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    /// Recomputes `filteredItems`. Call after any change to the listing or a filter.
    func refilter() {
        guard !suppressRefilter else { return }
        // Recursive search replaces the listing with (already name-matched) deep results.
        var items: [FileItem]
        if let searchResults, searchRecursively, !searchText.isEmpty {
            items = searchResults
        } else {
            items = allItems
            if !searchText.isEmpty {
                items = items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            }
        }
        if dateFilter != .any {
            items = items.filter { dateFilter.matches($0.modified) }
        }
        if sizeFilter != .any {
            items = items.filter { $0.isDirectory || sizeFilter.matches($0.size) }
        }

        let customFilters = CustomFilterStore.shared.filters.filter {
            selectedCustomFilterIDs.contains($0.id)
        }
        if !selectedCategories.isEmpty || !selectedExtensions.isEmpty || !customFilters.isEmpty {
            // Categories whose selection has been narrowed to specific extensions.
            let narrowedCategories = Set(selectedExtensions.map { FileTypeCategory.category(forExtension: $0) })
            items = items.filter { item in
                if customFilters.contains(where: { $0.matches(item) }) {
                    return true
                }
                if selectedExtensions.contains(item.ext), narrowedCategories.contains(item.category) {
                    return true
                }
                guard selectedCategories.contains(item.category) else { return false }
                return !narrowedCategories.contains(item.category)
            }
        }
        filteredItems = sorted(items)
    }

    func customFilterCount(_ filter: CustomFilter) -> Int {
        allItems.filter { filter.matches($0) }.count
    }

    func toggleCustomFilter(_ id: UUID) {
        if selectedCustomFilterIDs.contains(id) {
            selectedCustomFilterIDs.remove(id)
        } else {
            selectedCustomFilterIDs.insert(id)
        }
    }

    func toggleCategory(_ category: FileTypeCategory) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
            selectedExtensions = selectedExtensions.filter {
                FileTypeCategory.category(forExtension: $0) != category
            }
        } else {
            selectedCategories.insert(category)
        }
    }

    func toggleExtension(_ ext: String) {
        if selectedExtensions.contains(ext) {
            selectedExtensions.remove(ext)
        } else {
            selectedExtensions.insert(ext)
        }
    }

    func clearFilters() {
        suppressRefilter = true
        selectedCategories = []
        selectedExtensions = []
        selectedCustomFilterIDs = []
        searchText = ""
        dateFilter = .any
        sizeFilter = .any
        suppressRefilter = false
        refilter()
    }

    // MARK: - Selection

    func selectAll() {
        selection = Set(filteredItems.map(\.id))
    }

    func invertSelection() {
        selection = Set(filteredItems.map(\.id)).subtracting(selection)
    }

    /// Adds (or removes) every visible item whose name matches the wildcard pattern(s).
    func select(matching text: String, select: Bool = true) {
        let patterns = NamePattern.parse(text)
        guard !patterns.isEmpty else { return }
        let ids = filteredItems
            .filter { NamePattern.matches($0.name, patterns: patterns) }
            .map(\.id)
        if select {
            selection.formUnion(ids)
        } else {
            selection.subtract(ids)
        }
    }

    /// Selects every visible file sharing the extension of the first selected item
    /// (or every folder, if a folder is selected).
    func selectSameExtension() {
        guard let reference = selectedItems.first else { return }
        let ids = filteredItems.filter {
            reference.isDirectory ? $0.isDirectory : (!$0.isDirectory && $0.ext == reference.ext)
        }.map(\.id)
        selection.formUnion(ids)
    }

    /// First selected item in display order (what a keyboard action should act on).
    var focusedItem: FileItem? {
        filteredItems.first { selection.contains($0.id) }
    }

    // MARK: - Recursive search

    private func scheduleRecursiveSearch() {
        searchTask?.cancel()
        searchResults = nil
        isSearching = false
        guard searchRecursively, !searchText.isEmpty else { return }

        if let location = archiveLocation {
            // Archive listings are in memory: search the index directly.
            guard let index = ArchiveIndexCache.shared.cached(for: location.archiveURL) else { return }
            let query = searchText
            let scope = location.isRoot ? index.entries : index.descendants(of: location.path)
            let prefix = location.isRoot ? "" : location.path + "/"
            searchResults = scope
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .filter { showHiddenFiles || !$0.path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" } }
                .map { entry in
                    var item = FileItem(entry: entry, in: location.archiveURL)
                    let parent = entry.parentPath
                    let relative = parent.hasPrefix(prefix) ? String(parent.dropFirst(prefix.count)) : parent
                    item.searchPath = relative.isEmpty ? nil : relative
                    return item
                }
            return
        }

        let root = currentDirectory
        let query = searchText
        let includeHidden = showHiddenFiles
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)  // debounce typing
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                Self.deepSearch(root: root, query: query, includeHidden: includeHidden)
            }.value
            guard !Task.isCancelled else { return }
            self?.searchResults = results
            self?.isSearching = false
        }
    }

    nonisolated private static func deepSearch(
        root: URL, query: String, includeHidden: Bool
    ) -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        var found: [FileItem] = []
        // Canonicalize: the enumerator may report /private/var/… for a /var/… root.
        let rootPath = root.resolvingSymlinksInPath().path

        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: options)
        else { return found }

        for case let url as URL in enumerator {
            guard found.count < 2000 else { break }
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
            guard var item = FileItem(url: url) else { continue }
            let parentPath = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let relative = parentPath.hasPrefix(rootPath)
                ? String(parentPath.dropFirst(rootPath.count)) : parentPath
            item.searchPath = relative.isEmpty ? nil : String(relative.dropFirst())
            found.append(item)
        }
        return found
    }

    // MARK: - Keyboard navigation (grid)

    /// Arrow-key movement in grid view; returns true when the key was handled.
    func moveGridSelection(keyCode: UInt16) -> Bool {
        let items = filteredItems
        guard !items.isEmpty else { return false }
        let current = items.firstIndex { selection.contains($0.id) }

        var next: Int
        switch keyCode {
        case 123: next = (current ?? 1) - 1                        // ←
        case 124: next = current.map { $0 + 1 } ?? 0               // →
        case 125: next = current.map { $0 + gridColumnCount } ?? 0 // ↓
        case 126: next = (current ?? gridColumnCount) - gridColumnCount  // ↑
        default: return false
        }

        if items.indices.contains(next) {
            selection = [items[next].id]
        }
        return true
    }

    // MARK: - Sorting

    private func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var result: ComparisonResult
            switch sortField {
            case .name:
                result = .orderedSame
            case .size:
                result = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .date:
                result = a.modified == b.modified
                    ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .kind:
                result = a.kindText.localizedStandardCompare(b.kindText)
            }
            if result == .orderedSame {
                result = a.name.localizedStandardCompare(b.name)
            }
            if result == .orderedSame { return false }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
