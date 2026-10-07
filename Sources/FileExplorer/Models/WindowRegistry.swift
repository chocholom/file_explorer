import Foundation
import Observation

/// Tracks which window was key most recently so app-wide sheets (the conflict
/// dialog of the shared operation queue) appear in exactly one window.
@MainActor
@Observable
final class WindowRegistry {
    static let shared = WindowRegistry()
    var frontWindowID: UUID?
}
