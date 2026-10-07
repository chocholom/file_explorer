import Foundation
import Observation

/// App-wide undo for file operations (move, rename, trash, copy, convert, …).
/// Each entry knows how to reverse its operation; directory watchers refresh the views.
@MainActor
@Observable
final class UndoStack {
    static let shared = UndoStack()

    struct Entry {
        let name: String
        let undo: () -> Void
    }

    private(set) var entries: [Entry] = []

    var canUndo: Bool { !entries.isEmpty }
    var topName: String? { entries.last?.name }

    func push(_ name: String, undo: @escaping () -> Void) {
        entries.append(Entry(name: name, undo: undo))
        if entries.count > 50 {
            entries.removeFirst(entries.count - 50)
        }
    }

    func undo() {
        guard let entry = entries.popLast() else { return }
        entry.undo()
    }

    func clear() {
        entries.removeAll()
    }
}
