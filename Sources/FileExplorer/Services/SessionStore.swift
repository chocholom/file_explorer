import Foundation

/// Everything needed to bring a window back the way it was closed.
struct PaneSnapshot: Codable, Equatable {
    var path: String
    var viewMode: String
    var sortField: String
    var sortAscending: Bool
    var showHiddenFiles: Bool
}

struct TabSnapshot: Codable, Equatable {
    var primary: PaneSnapshot
    var secondary: PaneSnapshot?
    var secondaryIsActive: Bool
}

struct SessionSnapshot: Codable, Equatable {
    var tabs: [TabSnapshot]
    var selectedIndex: Int
}

enum SessionStore {
    private static let defaultsKey = "session"

    static func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// The saved session is restored into the first window only; windows opened
    /// later with ⌘N start at the home folder.
    @MainActor private static var restoredOnce = false

    @MainActor
    static func takeForLaunch() -> SessionSnapshot? {
        guard !restoredOnce else { return nil }
        restoredOnce = true
        return load()
    }
}
