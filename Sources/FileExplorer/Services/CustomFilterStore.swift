import Foundation
import Observation

/// A user-defined type filter, e.g. "3D Assets" → fbx, obj, blend.
struct CustomFilter: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var extensions: [String]

    /// Parses "fbx, obj, .blend" into normalized lowercase extensions.
    static func parseExtensions(_ text: String) -> [String] {
        text.split(whereSeparator: { ", ".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }

    func matches(_ item: FileItem) -> Bool {
        !item.isDirectory && extensions.contains(item.ext)
    }
}

@MainActor
@Observable
final class CustomFilterStore {
    static let shared = CustomFilterStore()
    private static let defaultsKey = "customFilters"

    var filters: [CustomFilter] {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([CustomFilter].self, from: data)
        {
            filters = decoded
        } else {
            filters = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(filters) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
