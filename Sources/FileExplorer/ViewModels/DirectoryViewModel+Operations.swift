import AppKit
import Foundation
import UniformTypeIdentifiers

/// Sheet payload for batch rename (Identifiable for .sheet(item:)).
struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let items: [FileItem]
}

extension NSPasteboard.PasteboardType {
    /// Newline-separated virtual paths of archive entries copied from a pane.
    static let virtualFiles = NSPasteboard.PasteboardType("local.mirek.FileExplorer.virtual-files")
}

// MARK: - File operations

extension DirectoryViewModel {
    var selectedItems: [FileItem] {
        // Recursive-search results aren't in allItems, so resolve against the visible list.
        let visible = filteredItems.filter { selection.contains($0.id) }
        if !visible.isEmpty { return visible }
        return allItems.filter { selection.contains($0.id) }
    }

    private var notAvailableInArchives: String { "This action isn't available inside archives." }

    // MARK: Trash / delete

    func trash(_ items: [FileItem]) {
        // Archives have no Trash: deleting entries is permanent, so confirm first.
        let entries = items.filter(\.isArchiveEntry)
        if !entries.isEmpty {
            requestPermanentDelete(entries)
            return
        }
        var errors: [String] = []
        var restorable: [(trashed: URL, original: URL)] = []
        for item in items {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? {
                    restorable.append((trashed, item.url))
                }
                selection.remove(item.id)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if !restorable.isEmpty {
            UndoStack.shared.push("Move to Trash") { [weak self] in
                for (trashed, original) in restorable.reversed() {
                    try? FileManager.default.moveItem(at: trashed, to: original)
                }
                self?.reload()
            }
        }
        reportErrors(errors)
        didMutate()
    }

    func trashSelection() {
        trash(selectedItems)
    }

    /// Shift-F8 / ⌥⌘⌫: asks for confirmation (via `pendingPermanentDelete`), then
    /// `confirmPermanentDelete()` removes the items for good. Not undoable.
    func requestPermanentDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.contains(where: \.isArchiveEntry), !isArchiveWritable {
            operationError = ArchiveWriter.ReadOnlyError(name: archiveLocation?.name ?? "archive").localizedDescription
            return
        }
        pendingPermanentDelete = items
    }

    func confirmPermanentDelete() {
        guard let items = pendingPermanentDelete else { return }
        pendingPermanentDelete = nil

        let entries = items.compactMap(\.archiveEntry)
        if let archive = entries.first?.archiveURL {
            let paths = entries.map(\.path)
            selection.subtract(items.map(\.id))
            runArchiveWrite("Deleting from “\(archive.lastPathComponent)”…") {
                let index = try ArchiveIndexCache.shared.index(for: archive)
                try ArchiveWriter.delete(paths, from: archive, index: index)
            }
            return
        }

        var errors: [String] = []
        for item in items {
            do {
                try FileManager.default.removeItem(at: item.url)
                selection.remove(item.id)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        reportErrors(errors)
        didMutate()
    }

    // MARK: Rename

    func beginRenamingSelection() {
        let items = selectedItems
        if items.count > 1 {
            if isInsideArchive {
                operationError = "Batch rename isn't available inside archives."
                return
            }
            batchRenameRequest = BatchRenameRequest(items: items)
        } else {
            renameTarget = items.first
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        guard !name.contains("/") else {
            operationError = "Names can't contain “/”."
            return
        }

        if let entry = item.archiveEntry {
            guard isArchiveWritable else {
                operationError = ArchiveWriter.ReadOnlyError(name: entry.archiveURL.lastPathComponent).localizedDescription
                return
            }
            if allItems.contains(where: { $0.name == name }) {
                operationError = "An item named “\(name)” already exists here."
                return
            }
            pendingSelection = (name, false)
            runArchiveWrite("Renaming in “\(entry.archiveURL.lastPathComponent)”…") {
                let index = try ArchiveIndexCache.shared.index(for: entry.archiveURL)
                guard let archiveEntry = index.entry(at: entry.path) else { return }
                try ArchiveWriter.rename(archiveEntry, to: name, in: entry.archiveURL, index: index)
            }
            return
        }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileSystemHelpers.exists(destination) else {
            operationError = "An item named “\(name)” already exists here."
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            selection.remove(item.id)
            selection.insert(destination)
            UndoStack.shared.push("Rename") { [weak self] in
                try? FileManager.default.moveItem(at: destination, to: item.url)
                self?.reload()
            }
        } catch {
            operationError = error.localizedDescription
        }
        didMutate()
    }

    // MARK: Batch rename

    func batchRename(_ items: [FileItem], mode: BatchRenamer.Mode) {
        guard !isInsideArchive else {
            operationError = notAvailableInArchives
            return
        }
        let newNames = BatchRenamer.apply(mode, to: items.map(\.name))
        var errors: [String] = []
        var performed: [(from: URL, to: URL)] = []
        let fm = FileManager.default

        // Two phases via temp names so in-set collisions (swaps, renumbering) can't clobber.
        var pending: [(temp: URL, final: String, original: URL)] = []
        for (item, newName) in zip(items, newNames) where newName != item.name && !newName.isEmpty {
            let temp = item.url.deletingLastPathComponent()
                .appendingPathComponent(".batchrename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: item.url, to: temp)
                pending.append((temp, newName, item.url))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        for entry in pending {
            let destination = uniqueDestination(
                for: entry.final, in: entry.temp.deletingLastPathComponent())
            do {
                try fm.moveItem(at: entry.temp, to: destination)
                performed.append((entry.original, destination))
            } catch {
                errors.append(error.localizedDescription)
                try? fm.moveItem(at: entry.temp, to: entry.original)  // roll back this one
            }
        }

        if !performed.isEmpty {
            UndoStack.shared.push("Batch Rename") { [weak self] in
                for (from, to) in performed.reversed() {
                    try? FileManager.default.moveItem(at: to, to: from)
                }
                self?.reload()
            }
        }
        selection = Set(performed.map(\.to))
        reportErrors(errors)
        didMutate()
    }

    // MARK: New folder / file

    @discardableResult
    func newFolder() -> FileItem? {
        if let location = archiveLocation {
            guard isArchiveWritable else {
                operationError = ArchiveWriter.ReadOnlyError(name: location.archiveURL.lastPathComponent).localizedDescription
                return nil
            }
            let name = firstFreeName(base: "untitled folder")
            pendingSelection = (name, true)
            let path = location.appending(name).path
            runArchiveWrite("Updating “\(location.archiveURL.lastPathComponent)”…") {
                try ArchiveWriter.createDirectory(path, in: location.archiveURL)
            }
            return nil
        }

        let name = firstFreeName(base: "untitled folder")
        let url = currentDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            operationError = error.localizedDescription
            return nil
        }
        return finishCreating(url, undoName: "New Folder")
    }

    /// ⇧F4 in Total Commander: creates an empty text file and starts renaming it.
    @discardableResult
    func newFile() -> FileItem? {
        guard !isInsideArchive else {
            operationError = notAvailableInArchives
            return nil
        }
        let name = firstFreeName(base: "untitled", ext: "txt")
        let url = currentDirectory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            operationError = "Couldn't create “\(name)”."
            return nil
        }
        return finishCreating(url, undoName: "New File")
    }

    private func firstFreeName(base: String, ext: String? = nil) -> String {
        func name(_ counter: Int) -> String {
            let stem = counter == 1 ? base : "\(base) \(counter)"
            return ext.map { "\(stem).\($0)" } ?? stem
        }
        let taken = Set(allItems.map(\.name))
        var counter = 1
        while taken.contains(name(counter))
            || (!isInsideArchive && FileSystemHelpers.exists(currentDirectory.appendingPathComponent(name(counter))))
        {
            counter += 1
        }
        return name(counter)
    }

    private func finishCreating(_ url: URL, undoName: String) -> FileItem? {
        UndoStack.shared.push(undoName) { [weak self] in
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            self?.reload()
        }
        reload()
        // Look up by name: contentsOfDirectory may return /private/var/… for a /var/… input.
        let item = allItems.first { $0.name == url.lastPathComponent }
        if let item {
            selection = [item.id]
            renameTarget = item
        }
        return item
    }

    // MARK: Duplicate

    func duplicate(_ items: [FileItem]) {
        guard !isInsideArchive else {
            operationError = notAvailableInArchives
            return
        }
        var errors: [String] = []
        var created: [URL] = []
        for item in items {
            let destination = uniqueDestination(
                for: item.name, in: item.url.deletingLastPathComponent())
            do {
                try FileManager.default.copyItem(at: item.url, to: destination)
                created.append(destination)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        pushTrashUndo(name: "Duplicate", created: created)
        reportErrors(errors)
        didMutate()
    }

    func duplicateSelection() {
        duplicate(selectedItems)
    }

    // MARK: Pasteboard (cut / copy / paste)

    func copyToPasteboard(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let real = items.filter { !$0.isArchiveEntry }
        if !real.isEmpty {
            pasteboard.writeObjects(real.map { $0.url as NSURL })
        }
        let virtual = items.filter(\.isArchiveEntry)
        if !virtual.isEmpty {
            let item = NSPasteboardItem()
            item.setString(virtual.map(\.url.path).joined(separator: "\n"), forType: .virtualFiles)
            pasteboard.writeObjects([item])
        }
        FileClipboard.shared.clearCut()
    }

    func copySelectionToPasteboard() {
        copyToPasteboard(selectedItems)
    }

    func cutToPasteboard(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        guard !items.contains(where: \.isArchiveEntry) else {
            operationError = "Cut isn't available inside archives; use Move (F6) instead."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { $0.url as NSURL })
        FileClipboard.shared.markCut(items.map(\.url))
    }

    func cutSelectionToPasteboard() {
        cutToPasteboard(selectedItems)
    }

    func pasteFromPasteboard(policy: ConflictPolicy = .ask) {
        let pasteboard = NSPasteboard.general
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        if let virtual = pasteboard.string(forType: .virtualFiles) {
            urls += virtual.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        let existing = urls.filter { FileSystemHelpers.exists($0) || ArchiveLocator.locate($0) != nil }
        guard !existing.isEmpty else { return }

        // Compare canonical paths, not URLs: a folder URL round-tripped through the
        // pasteboard may gain a trailing slash and would otherwise fail the cut check.
        let cutPaths = Set(FileClipboard.shared.cutURLs.map(FileSystemHelpers.canonicalPath))
        let pastedPaths = Set(existing.map(FileSystemHelpers.canonicalPath))
        if !cutPaths.isEmpty, pastedPaths.isSubset(of: cutPaths) {
            FileClipboard.shared.clearCut()
            transfer(existing, kind: .move, to: currentDirectory, forceMove: true, policy: policy)
        } else {
            transfer(existing, kind: .copy, to: currentDirectory, policy: policy)
        }
    }

    // MARK: Move / copy (drag & drop, cut-paste, F5/F6)

    /// Finder drag semantics: same volume moves, across volumes copies.
    /// `forceMove` (cut-paste, F6) moves even across volumes (copy + remove source).
    func moveOrCopy(_ sources: [URL], into destinationDir: URL, forceMove: Bool = false,
                    policy: ConflictPolicy = .ask) {
        transfer(sources, kind: .move, to: destinationDir, forceMove: forceMove, policy: policy)
    }

    /// Runs the transfer on the shared background queue. Sources and the destination
    /// may be inside archives (see `TransferWorker`). Completion registers undo,
    /// reports errors and refreshes the listing.
    func transfer(_ sources: [URL], kind: FileTransfer.Kind, to destinationDir: URL,
                  forceMove: Bool = false, policy: ConflictPolicy = .ask) {
        let destination = destinationDir.standardizedFileURL
        let destinationPath = FileSystemHelpers.canonicalPath(destination)
        var errors: [String] = []
        var accepted: [URL] = []

        if let archive = ArchiveLocator.locate(destination), !archive.format.isWritable {
            operationError = ArchiveWriter.ReadOnlyError(name: archive.archiveURL.lastPathComponent).localizedDescription
            return
        }

        for source in sources.map(\.standardizedFileURL) {
            let sourcePath = FileSystemHelpers.canonicalPath(source)
            if sourcePath == destinationPath {
                continue  // dropping a folder onto itself
            }
            if destinationPath.hasPrefix(sourcePath + "/") {
                errors.append("Can't \(kind == .copy ? "copy" : "move") “\(source.lastPathComponent)” into itself.")
                continue
            }
            if kind == .move, source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == destinationPath {
                continue  // already there
            }
            if kind == .move, let origin = ArchiveLocator.locate(source), !origin.format.isWritable {
                errors.append("“\(origin.archiveURL.lastPathComponent)” is read-only; “\(source.lastPathComponent)” can be copied but not moved out.")
                continue
            }
            accepted.append(source)
        }
        reportErrors(errors)
        guard !accepted.isEmpty else { return }

        let request = FileTransfer(kind: kind, sources: accepted, destinationDirectory: destination, forceMove: forceMove)
        let undoName = kind == .copy ? "Copy" : "Move"
        FileOperationQueue.shared.enqueue(request, policy: policy) { [weak self] outcome in
            self?.finishTransfer(outcome, undoName: undoName, destination: destination)
        }
    }

    private func finishTransfer(_ outcome: TransferOutcome, undoName: String, destination: URL) {
        if outcome.changedAnything {
            UndoStack.shared.push(undoName) { [weak self] in
                let fm = FileManager.default
                for (from, to) in outcome.moved.reversed() {
                    // A merged-and-moved folder was removed once empty; recreate the path.
                    try? fm.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: to, to: from)
                }
                for url in outcome.copied.reversed() {
                    try? fm.trashItem(at: url, resultingItemURL: nil)
                }
                for (trashed, original) in outcome.replaced.reversed() {
                    try? fm.moveItem(at: trashed, to: original)
                }
                for (archive, paths) in outcome.archiveAdded.reversed() {
                    if let index = try? ArchiveIndexCache.shared.index(for: archive) {
                        try? ArchiveWriter.delete(paths, from: archive, index: index)
                    }
                }
                for (trashed, original) in outcome.movedToTrash.reversed() {
                    try? fm.moveItem(at: trashed, to: original)
                }
                self?.reload()
            }
        }
        var errors = outcome.errors
        if outcome.cancelled, outcome.changedAnything {
            errors.append("The operation was cancelled; items already transferred were kept (⌘Z undoes them).")
        }
        reportErrors(errors)
        FolderSizeStore.shared.invalidate(under: destination)
        didMutate()
    }

    // MARK: Archives

    /// Extracts (copies out) everything in the archive into a new folder named after it.
    func extract(_ archive: FileItem, into destinationFolder: URL) {
        guard archive.isArchive else { return }
        let archiveURL = archive.url
        let folderName = Self.archiveStem(archive.name)
        archiveActivity = "Indexing “\(archive.name)”…"
        Task.detached(priority: .userInitiated) {
            let result = Result { try ArchiveIndexCache.shared.index(for: archiveURL) }
            await MainActor.run {
                self.archiveActivity = nil
                switch result {
                case .failure(let error):
                    self.operationError = error.localizedDescription
                case .success(let index):
                    let target = self.uniqueDestination(for: folderName, in: destinationFolder)
                    do {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    } catch {
                        self.operationError = error.localizedDescription
                        return
                    }
                    let roots = index.children(of: "").map { ArchivePath(archiveURL: archiveURL, path: $0.path).virtualURL }
                    guard !roots.isEmpty else { return }
                    self.transfer(roots, kind: .copy, to: target, policy: .always(.replace))
                }
            }
        }
    }

    /// "photos.tar.gz" → "photos", "Backup.zip" → "Backup".
    nonisolated static func archiveStem(_ name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        if stem.lowercased().hasSuffix(".tar") { stem = String(stem.dropLast(4)) }
        return stem.isEmpty ? name : stem
    }

    /// Real file URLs for the items: archive entries are extracted to the cache first
    /// (off the main thread), then `completion` runs on the main actor.
    func materialize(_ items: [FileItem], then completion: @escaping @MainActor @Sendable ([URL]) -> Void) {
        let real = items.filter { !$0.isArchiveEntry }.map(\.url)
        let virtual = items.compactMap(\.archiveEntry)
        guard !virtual.isEmpty else {
            completion(real)
            return
        }
        archiveActivity = "Extracting…"
        Task.detached(priority: .userInitiated) {
            var urls = real
            var errors: [String] = []
            for entry in virtual {
                do {
                    urls.append(try ArchiveCache.shared.materialize(entry))
                } catch {
                    errors.append("\(entry.name): \(error.localizedDescription)")
                }
            }
            let result = urls
            let failures = errors
            await MainActor.run {
                self.archiveActivity = nil
                self.reportErrors(failures)
                completion(result)
            }
        }
    }

    /// Opens files with their default application (archive entries are extracted first).
    func open(_ items: [FileItem]) {
        materialize(items) { urls in
            for url in urls { NSWorkspace.shared.open(url) }
        }
    }

    func quickLook(_ item: FileItem) {
        if item.isArchiveEntry {
            materialize([item]) { [weak self] urls in
                if let url = urls.first { self?.quickLookItem = url }
            }
        } else {
            quickLookItem = item.url
        }
    }

    /// Runs a ZIP modification off the main thread, showing `activity` in the pane,
    /// then refreshes (the writer invalidates the index; reload re-indexes).
    private func runArchiveWrite(_ activity: String, _ work: @escaping @Sendable () throws -> Void) {
        archiveActivity = activity
        Task.detached(priority: .userInitiated) {
            let result = Result(catching: work)
            await MainActor.run {
                self.archiveActivity = nil
                if case .failure(let error) = result {
                    self.pendingSelection = nil
                    self.operationError = error.localizedDescription
                }
                self.didMutate()
            }
        }
    }

    // MARK: Convert images

    func convertImages(_ items: [FileItem], to format: ImageConverter.Format) {
        guard !isInsideArchive else {
            operationError = notAvailableInArchives
            return
        }
        let convertible = items.filter { ImageConverter.canConvert($0) }
        guard !convertible.isEmpty else { return }
        let jobs = convertible.map { item in
            (source: item.url,
             destination: uniqueDestination(
                for: (item.name as NSString).deletingPathExtension + "." + format.fileExtension,
                in: item.url.deletingLastPathComponent()))
        }
        Task { [weak self] in
            // Decoding RAW/HEIC is slow; keep it off the main actor.
            let (created, errors) = await Task.detached(priority: .userInitiated) {
                var errors: [String] = []
                var created: [URL] = []
                for job in jobs {
                    do {
                        created.append(try ImageConverter.convert(job.source, to: format, destination: job.destination))
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                }
                return (created, errors)
            }.value
            guard let self else { return }
            self.pushTrashUndo(name: "Convert", created: created)
            self.reportErrors(errors)
            self.didMutate()
        }
    }

    // MARK: Compress

    func compress(_ items: [FileItem]) {
        guard !isInsideArchive else {
            operationError = notAvailableInArchives
            return
        }
        guard let first = items.first else { return }
        let archiveName =
            items.count == 1
            ? (first.name as NSString).deletingPathExtension + ".zip"
            : "Archive.zip"
        let destination = uniqueDestination(
            for: archiveName, in: first.url.deletingLastPathComponent())
        let urls = items.map(\.url)
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Archiver.compress(urls, into: destination)
                }.value
                UndoStack.shared.push("Compress") { [weak self] in
                    try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                    self?.reload()
                }
            } catch {
                self?.operationError = error.localizedDescription
            }
            self?.didMutate()
        }
    }

    // MARK: Open in Terminal / editor / other apps

    func openInTerminal(_ url: URL? = nil) {
        let target = url ?? currentDirectory
        guard ArchiveLocator.locate(target) == nil else {
            operationError = notAvailableInArchives
            return
        }
        let workspace = NSWorkspace.shared
        let iterm = workspace.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
        let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let app = iterm ?? terminal else {
            operationError = "No terminal application found."
            return
        }
        workspace.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// F4: opens files in the configured editor (or the first installed of VS Code,
    /// Sublime Text, BBEdit, TextEdit). Archive entries open as extracted copies.
    func edit(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        guard let editor = Self.editorURL() else {
            operationError = "No text editor found."
            return
        }
        materialize(items) { urls in
            NSWorkspace.shared.open(urls, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func editorURL() -> URL? {
        var candidates = [
            "com.microsoft.VSCode", "com.sublimetext.4", "com.sublimetext.3",
            "com.barebones.bbedit", "com.apple.TextEdit",
        ]
        if let preferred = AppSettings.shared.editorBundleID {
            candidates.insert(preferred, at: 0)
        }
        let workspace = NSWorkspace.shared
        return candidates.lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Applications able to open every one of the given files (for an "Open With" menu).
    nonisolated static func applications(toOpen items: [FileItem]) -> [URL] {
        let files = items.filter { !$0.isDirectory }
        guard let first = files.first else { return [] }
        // Virtual entries don't exist on disk; ask by file type instead.
        func candidates(_ item: FileItem) -> Set<URL> {
            if item.isArchiveEntry {
                guard let type = UTType(filenameExtension: item.ext) else { return [] }
                return Set(NSWorkspace.shared.urlsForApplications(toOpen: type))
            }
            return Set(NSWorkspace.shared.urlsForApplications(toOpen: item.url))
        }
        var common = candidates(first)
        for item in files.dropFirst() {
            common.formIntersection(candidates(item))
        }
        return common.sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
    }

    func open(_ items: [FileItem], with application: URL) {
        materialize(items) { urls in
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Helpers

    /// First free Finder-style name: "name.ext", "name copy.ext", "name copy 2.ext", …
    func uniqueDestination(for name: String, in directory: URL) -> URL {
        FileSystemHelpers.uniqueDestination(for: name, in: directory)
    }

    private func pushTrashUndo(name: String, created: [URL]) {
        guard !created.isEmpty else { return }
        UndoStack.shared.push(name) { [weak self] in
            for url in created {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            self?.reload()
        }
    }

    private func reportErrors(_ errors: [String]) {
        guard !errors.isEmpty else { return }
        operationError = errors.joined(separator: "\n")
    }

    /// Refresh after a mutation and drop stale cached folder sizes.
    private func didMutate() {
        if let location = archiveLocation {
            ArchiveIndexCache.shared.invalidate(location.archiveURL)
        } else {
            FolderSizeStore.shared.invalidate(under: currentDirectory)
        }
        reload()
    }
}
