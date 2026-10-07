import AppKit
import Foundation

// MARK: - Model types

/// What to do when an item with the same name already exists at the destination.
enum ConflictResolution: String, Sendable, CaseIterable {
    case replace  // the existing item goes to the Trash, then the source is transferred
    case keepBoth  // Finder-style "name copy.ext"
    case skip
    case merge  // folders only: transfer children into the existing folder
    case cancel

    var title: String {
        switch self {
        case .replace: return "Replace"
        case .keepBoth: return "Keep Both"
        case .skip: return "Skip"
        case .merge: return "Merge"
        case .cancel: return "Cancel"
        }
    }
}

enum ConflictPolicy: Sendable {
    case ask
    case always(ConflictResolution)
}

struct FileConflict: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let destination: URL
    let bothDirectories: Bool
    /// nil for folders (not measured to keep the dialog instant).
    let sourceSize: Int64?
    let destinationSize: Int64?
    let sourceModified: Date?
    let destinationModified: Date?
}

struct FileTransfer: Sendable {
    enum Kind: Sendable {
        case copy, move
    }

    let kind: Kind
    let sources: [URL]
    let destinationDirectory: URL
    /// Cut-paste / F6: move even across volumes (copy + remove source).
    /// Without it a cross-volume "move" copies, like a Finder drag.
    var forceMove = false

    var title: String {
        let verb = kind == .copy ? "Copying" : "Moving"
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        let destination = destinationDirectory.lastPathComponent.isEmpty
            ? "/" : destinationDirectory.lastPathComponent
        return "\(verb) \(what) to “\(destination)”"
    }
}

struct TransferOutcome: Sendable {
    var moved: [(from: URL, to: URL)] = []
    var copied: [URL] = []
    var replaced: [(trashed: URL, original: URL)] = []
    /// Entries added to a ZIP (undo deletes them again).
    var archiveAdded: [(archive: URL, paths: [String])] = []
    /// Sources trashed after being moved into a ZIP (undo restores them).
    var movedToTrash: [(trashed: URL, original: URL)] = []
    /// Entries deleted from a ZIP after being moved out (not undoable).
    var archiveRemoved: [(archive: URL, paths: [String])] = []
    var skipped = 0
    var errors: [String] = []
    var cancelled = false

    var changedAnything: Bool {
        !moved.isEmpty || !copied.isEmpty || !replaced.isEmpty || !archiveAdded.isEmpty
            || !movedToTrash.isEmpty || !archiveRemoved.isEmpty
    }
}

struct OperationProgress: Sendable, Equatable {
    var title: String
    var currentName = ""
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var completedItems = 0
    var totalItems = 0

    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return min(1, Double(completedItems) / Double(totalItems)) }
        return 0
    }
}

// MARK: - Queue

/// Serial queue of copy/move operations. Work runs off the main thread; progress,
/// conflicts and completion are published on the main actor so views can bind to them.
@MainActor
@Observable
final class FileOperationQueue {
    static let shared = FileOperationQueue()

    private(set) var progress: OperationProgress?
    /// Set while the worker waits for the user to pick a `ConflictResolution`.
    private(set) var pendingConflict: FileConflict?

    private struct Job {
        let transfer: FileTransfer
        let policy: ConflictPolicy
        let completion: @MainActor @Sendable (TransferOutcome) -> Void
    }

    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var conflictContinuation:
        CheckedContinuation<(ConflictResolution, Bool), Never>?

    var isBusy: Bool { progress != nil }

    func enqueue(
        _ transfer: FileTransfer,
        policy: ConflictPolicy = .ask,
        completion: @escaping @MainActor @Sendable (TransferOutcome) -> Void = { _ in }
    ) {
        pending.append(Job(transfer: transfer, policy: policy, completion: completion))
        startNextIfIdle()
    }

    /// Cancels the running operation (and dismisses a pending conflict dialog).
    func cancel() {
        task?.cancel()
        if conflictContinuation != nil {
            resolvePendingConflict(.cancel, applyToAll: false)
        }
    }

    func resolvePendingConflict(_ resolution: ConflictResolution, applyToAll: Bool) {
        pendingConflict = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: (resolution, applyToAll))
    }

    /// Suspends until every queued operation has finished (tests, scripting).
    func waitUntilIdle() async {
        while task != nil || !pending.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func startNextIfIdle() {
        guard task == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        progress = OperationProgress(title: job.transfer.title)

        let worker = TransferWorker(
            transfer: job.transfer,
            policy: job.policy,
            resolve: { [weak self] conflict in
                await self?.ask(conflict) ?? (.skip, false)
            },
            report: { [weak self] progress in
                Task { @MainActor in self?.progress = progress }
            })

        // Strong capture is fine: the queue is a singleton and must outlive its work.
        task = Task.detached(priority: .userInitiated) {
            let outcome = await worker.run()
            await self.finish(outcome, job: job)
        }
    }

    private func ask(_ conflict: FileConflict) async -> (ConflictResolution, Bool) {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            pendingConflict = conflict
        }
    }

    private func finish(_ outcome: TransferOutcome, job: Job) {
        progress = nil
        task = nil
        job.completion(outcome)
        startNextIfIdle()
    }
}

// MARK: - Worker

/// Performs one transfer. Folders are copied child by child so progress advances
/// per file, a single unreadable file doesn't abort the folder, and conflicts
/// inside merged folders get the same treatment as top-level ones.
///
/// Archives: sources inside an archive are extracted to a staging folder first and
/// then moved into place (recorded as copies); a destination inside a ZIP is filled
/// by staging the sources under the entry path and running `zip -r`.
actor TransferWorker {
    private let transfer: FileTransfer
    private var policy: ConflictPolicy
    private let resolve: @Sendable (FileConflict) async -> (ConflictResolution, Bool)
    private let report: @Sendable (OperationProgress) -> Void

    private var progress: OperationProgress
    private var outcome = TransferOutcome()
    private var lastReport = Date.distantPast
    private var measured: [String: (items: Int, bytes: Int64)] = [:]

    private enum Abort: Error {
        case cancelled
    }

    private static let itemKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    init(
        transfer: FileTransfer,
        policy: ConflictPolicy,
        resolve: @escaping @Sendable (FileConflict) async -> (ConflictResolution, Bool),
        report: @escaping @Sendable (OperationProgress) -> Void
    ) {
        self.transfer = transfer
        self.policy = policy
        self.resolve = resolve
        self.report = report
        progress = OperationProgress(title: transfer.title)
    }

    func run() async -> TransferOutcome {
        let fm = FileManager.default
        let destinationArchive = ArchiveLocator.locate(transfer.destinationDirectory)
        if let destinationArchive, !destinationArchive.format.isWritable {
            outcome.errors.append(ArchiveWriter.ReadOnlyError(name: destinationArchive.archiveURL.lastPathComponent).localizedDescription)
            return outcome
        }

        // Sources that live inside archives are extracted to a staging folder first.
        var staging: URL?
        defer { if let staging { try? fm.removeItem(at: staging) } }
        var sources: [(url: URL, origin: ArchivePath?)] = []
        for source in transfer.sources {
            guard let origin = ArchiveLocator.locate(source) else {
                sources.append((source, nil))
                continue
            }
            progress.currentName = "Extracting “\(origin.name)”…"
            publish(force: true)
            do {
                let root = try staging ?? ArchiveWriter.makeStaging()
                staging = root
                let folder = root.appendingPathComponent(UUID().uuidString)
                try SystemTar.extract([origin.path], from: origin.archiveURL, to: folder)
                sources.append((folder.appendingPathComponent(origin.path), origin))
            } catch let error where Self.isAbort(error) {
                outcome.cancelled = true
                return outcome
            } catch {
                outcome.errors.append("\(origin.name): \(error.localizedDescription)")
            }
        }

        for (source, _) in sources {
            let size = Self.measure(source)
            measured[source.path] = size
            progress.totalItems += size.items
            progress.totalBytes += size.bytes
        }
        publish(force: true)

        var transferredOrigins: [ArchivePath] = []
        if let destinationArchive {
            do {
                transferredOrigins = try await addToArchive(sources, destination: destinationArchive)
            } catch let error where Self.isAbort(error) {
                outcome.cancelled = true
            } catch {
                outcome.errors.append(error.localizedDescription)
            }
        } else {
            for (source, origin) in sources {
                do {
                    try Task.checkCancellation()
                    let skippedBefore = outcome.skipped
                    let errorsBefore = outcome.errors.count
                    try await transferItem(source, into: transfer.destinationDirectory, disposable: origin != nil)
                    if let origin, outcome.skipped == skippedBefore, outcome.errors.count == errorsBefore {
                        transferredOrigins.append(origin)
                    }
                } catch let error where Self.isAbort(error) {
                    outcome.cancelled = true
                    break
                } catch {
                    outcome.errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Moving out of a ZIP: remove the entries that made it across.
        if transfer.kind == .move, !transferredOrigins.isEmpty {
            let grouped = Dictionary(grouping: transferredOrigins, by: \.archiveURL)
            for (archive, origins) in grouped {
                guard ArchiveFormat.detect(archive)?.isWritable == true else { continue }
                progress.currentName = "Updating “\(archive.lastPathComponent)”…"
                publish(force: true)
                do {
                    let index = try ArchiveIndexCache.shared.index(for: archive)
                    try ArchiveWriter.delete(origins.map(\.path), from: archive, index: index)
                    outcome.archiveRemoved.append((archive, origins.map(\.path)))
                } catch {
                    outcome.errors.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        publish(force: true)
        return outcome
    }

    // MARK: Into a ZIP

    /// Stages the sources under the destination entry path and adds them with one
    /// `zip -r`. Conflicts are checked against the index at the top level; inside merged
    /// folders zip updates same-named files. Returns the archive origins that were added.
    private func addToArchive(_ sources: [(url: URL, origin: ArchivePath?)], destination: ArchivePath) async throws -> [ArchivePath] {
        let fm = FileManager.default
        let index = try ArchiveIndexCache.shared.index(for: destination.archiveURL)
        var existingNames = Set(index.children(of: destination.path).map(\.name))
        let staging = try ArchiveWriter.makeStaging()
        defer { try? fm.removeItem(at: staging) }
        let innerDirectory = destination.isRoot ? staging : staging.appendingPathComponent(destination.path)
        try fm.createDirectory(at: innerDirectory, withIntermediateDirectories: true)

        var added: [String] = []
        var replacedPaths: [String] = []
        var transferred: [(url: URL, origin: ArchivePath?)] = []

        for (source, origin) in sources {
            try Task.checkCancellation()
            var name = source.lastPathComponent
            let isDirectory = FileSystemHelpers.isDirectory(source)
            let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            progress.currentName = name
            publish()

            if existingNames.contains(name) {
                let existing = index.entry(at: destination.appending(name).path)
                let conflict = FileConflict(
                    source: source,
                    destination: destination.appending(name).virtualURL,
                    bothDirectories: isDirectory && existing?.isDirectory == true,
                    sourceSize: isDirectory ? nil : values?.fileSize.map(Int64.init),
                    destinationSize: existing?.isDirectory == true ? nil : existing?.size,
                    sourceModified: values?.contentModificationDate,
                    destinationModified: existing?.modified)
                switch await decide(conflict) {
                case .skip:
                    skip(source, isDirectory: isDirectory, fileSize: Int64(values?.fileSize ?? 0))
                    continue
                case .cancel:
                    throw Abort.cancelled
                case .keepBoth:
                    name = Self.uniqueName(name, avoiding: existingNames)
                case .replace:
                    replacedPaths.append(destination.appending(name).path)
                case .merge:
                    break  // zip -r merges folder contents
                }
            }

            try fm.copyItem(at: source, to: innerDirectory.appendingPathComponent(name))  // APFS clone
            existingNames.insert(name)
            added.append(destination.appending(name).path)
            transferred.append((source, origin))
            let size = measured[source.path] ?? Self.measure(source)
            progress.completedItems += size.items
            credit(size.bytes)
        }
        guard !added.isEmpty else { return [] }

        progress.currentName = "Compressing into “\(destination.archiveURL.lastPathComponent)”…"
        publish(force: true)
        if !replacedPaths.isEmpty {
            try ArchiveWriter.delete(replacedPaths, from: destination.archiveURL, index: index)
        }
        try ArchiveWriter.add(relativePaths: added, stagedIn: staging, to: destination.archiveURL)
        outcome.archiveAdded.append((destination.archiveURL, added))

        if transfer.kind == .move {
            // Real sources go to the Trash (undoable); staged ones are temp files.
            for (source, origin) in transferred where origin == nil {
                var trashed: NSURL?
                do {
                    try fm.trashItem(at: source, resultingItemURL: &trashed)
                    if let trashed { outcome.movedToTrash.append((trashed as URL, source)) }
                } catch {
                    outcome.errors.append("“\(source.lastPathComponent)” was added to the archive but couldn't be removed: \(error.localizedDescription)")
                }
            }
        }
        return transferred.compactMap(\.origin)
    }

    nonisolated private static func uniqueName(_ name: String, avoiding taken: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        var candidate = name
        while taken.contains(candidate) {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            candidate = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            counter += 1
        }
        return candidate
    }

    // MARK: Transfer of one item

    /// `disposable`: the source is a staged extraction (temp file) — move it into place
    /// instead of copying, but record the result as a copy.
    private func transferItem(_ source: URL, into directory: URL, disposable: Bool = false) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: Self.itemKeys)
        let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
        let fileSize = Int64(values.fileSize ?? 0)
        var destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: isDirectory)

        progress.currentName = source.lastPathComponent
        publish()

        if FileSystemHelpers.canonicalPath(destination) == FileSystemHelpers.canonicalPath(source) {
            // Copying into the item's own folder duplicates it; moving there is a no-op.
            guard transfer.kind == .copy else {
                skip(source, isDirectory: isDirectory, fileSize: fileSize)
                return
            }
            destination = FileSystemHelpers.uniqueDestination(for: source.lastPathComponent, in: directory)
        } else if FileSystemHelpers.exists(destination) {
            let destinationValues = try? destination.resourceValues(forKeys: Self.itemKeys)
            let destinationIsDirectory =
                destinationValues?.isDirectory == true && destinationValues?.isSymbolicLink != true
            let conflict = FileConflict(
                source: source,
                destination: destination,
                bothDirectories: isDirectory && destinationIsDirectory,
                sourceSize: isDirectory ? nil : fileSize,
                destinationSize: destinationIsDirectory ? nil : destinationValues?.fileSize.map(Int64.init),
                sourceModified: values.contentModificationDate,
                destinationModified: destinationValues?.contentModificationDate)

            switch await decide(conflict) {
            case .skip:
                skip(source, isDirectory: isDirectory, fileSize: fileSize)
                return
            case .cancel:
                throw Abort.cancelled
            case .keepBoth:
                destination = FileSystemHelpers.uniqueDestination(
                    for: source.lastPathComponent, in: directory)
            case .merge where conflict.bothDirectories:
                try await merge(source, into: destination, disposable: disposable)
                return
            case .replace, .merge:
                // Replaced items go to the Trash so the operation stays undoable.
                var trashed: NSURL?
                do {
                    try fm.trashItem(at: destination, resultingItemURL: &trashed)
                    if let trashed { outcome.replaced.append((trashed as URL, destination)) }
                } catch {
                    try fm.removeItem(at: destination)  // volumes without a Trash
                }
            }
        }

        try await perform(source, to: destination, isDirectory: isDirectory, fileSize: fileSize, disposable: disposable)
    }

    private func decide(_ conflict: FileConflict) async -> ConflictResolution {
        switch policy {
        case .always(let resolution):
            if resolution == .merge, !conflict.bothDirectories { return .replace }
            return resolution
        case .ask:
            let (resolution, applyToAll) = await resolve(conflict)
            if applyToAll, resolution != .cancel {
                policy = .always(resolution)
            }
            return resolution
        }
    }

    private func skip(_ source: URL, isDirectory: Bool, fileSize: Int64) {
        outcome.skipped += 1
        let size = measured[source.path] ?? (isDirectory ? Self.measure(source) : (1, fileSize))
        progress.completedItems += size.items
        credit(size.bytes)
    }

    private func perform(_ source: URL, to destination: URL, isDirectory: Bool, fileSize: Int64, disposable: Bool = false) async throws {
        let fm = FileManager.default
        let wantsMove = transfer.kind == .move
        let sameVolume =
            FileSystemHelpers.volumeID(of: source)
            == FileSystemHelpers.volumeID(of: destination.deletingLastPathComponent())

        if disposable {
            // Staged extraction from an archive: move the temp file into place.
            if sameVolume {
                try fm.moveItem(at: source, to: destination)
                let size = measured[source.path] ?? (isDirectory ? Self.measure(destination) : (1, fileSize))
                progress.completedItems += size.items
                credit(size.bytes)
            } else if isDirectory {
                _ = try await copyDirectory(source, to: destination)
            } else {
                try fm.copyItem(at: source, to: destination)
                progress.completedItems += 1
                credit(fileSize)
            }
            outcome.copied.append(destination)
            publish()
            return
        }

        if wantsMove, sameVolume {
            try fm.moveItem(at: source, to: destination)
            outcome.moved.append((source, destination))
            let size = measured[source.path] ?? (isDirectory ? Self.measure(destination) : (1, fileSize))
            progress.completedItems += size.items
            credit(size.bytes)
        } else if wantsMove, transfer.forceMove {
            let complete: Bool
            if isDirectory {
                complete = try await copyDirectory(source, to: destination)
            } else {
                try fm.copyItem(at: source, to: destination)
                progress.completedItems += 1
                credit(fileSize)
                complete = true
            }
            if complete {
                try fm.removeItem(at: source)
                outcome.moved.append((source, destination))
            } else {
                // Never delete a source that wasn't fully copied; keep the partial copy undoable.
                outcome.copied.append(destination)
                outcome.errors.append("“\(source.lastPathComponent)” was copied only partially and was left in place.")
            }
        } else {
            if isDirectory {
                _ = try await copyDirectory(source, to: destination)
            } else {
                try fm.copyItem(at: source, to: destination)
                progress.completedItems += 1
                credit(fileSize)
            }
            outcome.copied.append(destination)
        }
        publish()
    }

    /// Copies a folder child by child. Returns false if any child failed.
    private func copyDirectory(_ source: URL, to destination: URL) async throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        progress.completedItems += 1
        var complete = true

        let children = try fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: Array(Self.itemKeys), options: [])
        for child in children {
            try Task.checkCancellation()
            let values = try? child.resourceValues(forKeys: Self.itemKeys)
            let childIsDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: childIsDirectory)
            progress.currentName = child.lastPathComponent
            do {
                if childIsDirectory {
                    if try await copyDirectory(child, to: target) == false { complete = false }
                } else {
                    try fm.copyItem(at: child, to: target)
                    progress.completedItems += 1
                    credit(Int64(values?.fileSize ?? 0))
                }
            } catch let error where Self.isAbort(error) {
                throw error
            } catch {
                complete = false
                outcome.errors.append("\(child.lastPathComponent): \(error.localizedDescription)")
            }
            publish()
        }

        // Keep the folder's own date and permissions, as copyItem would have.
        if let attributes = try? fm.attributesOfItem(atPath: source.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let date = attributes[.modificationDate] { keep[.modificationDate] = date }
            if let permissions = attributes[.posixPermissions] { keep[.posixPermissions] = permissions }
            try? fm.setAttributes(keep, ofItemAtPath: destination.path)
        }
        return complete
    }

    /// Folder-into-existing-folder: children are transferred individually, each with
    /// its own conflict check. A moved folder is removed once it has been emptied.
    private func merge(_ source: URL, into destination: URL, disposable: Bool = false) async throws {
        let fm = FileManager.default
        progress.completedItems += 1
        let children = try fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: Array(Self.itemKeys), options: [])
        for child in children {
            do {
                try await transferItem(child, into: destination, disposable: disposable)
            } catch let error where Self.isAbort(error) {
                throw error
            } catch {
                outcome.errors.append("\(child.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if transfer.kind == .move || disposable,
            (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true
        {
            try fm.removeItem(at: source)
        }
    }

    // MARK: Helpers

    private func credit(_ bytes: Int64) {
        progress.completedBytes += bytes
        publish()
    }

    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.05 else { return }
        lastReport = now
        report(progress)
    }

    nonisolated private static func isAbort(_ error: Error) -> Bool {
        error is CancellationError || error is Abort
    }

    /// Item count and byte total of a file or folder tree (metadata only, no reads).
    nonisolated static func measure(_ url: URL) -> (items: Int, bytes: Int64) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (1, 0) }
        let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
        guard isDirectory else { return (1, Int64(values.fileSize ?? 0)) }

        var items = 1
        var bytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [])
        {
            for case let child as URL in enumerator {
                items += 1
                if let childValues = try? child.resourceValues(forKeys: keys),
                    childValues.isDirectory != true || childValues.isSymbolicLink == true
                {
                    bytes += Int64(childValues.fileSize ?? 0)
                }
            }
        }
        return (items, bytes)
    }
}
