import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var calculateFolderSizes: Bool {
        didSet { UserDefaults.standard.set(calculateFolderSizes, forKey: "calculateFolderSizes") }
    }
    var listThumbnails: Bool {
        didSet { UserDefaults.standard.set(listThumbnails, forKey: "listThumbnails") }
    }
    var hoverPreview: Bool {
        didSet { UserDefaults.standard.set(hoverPreview, forKey: "hoverPreview") }
    }
    /// Total Commander-style F2…F8 button bar at the bottom of the window.
    var showFunctionKeyBar: Bool {
        didSet { UserDefaults.standard.set(showFunctionKeyBar, forKey: "showFunctionKeyBar") }
    }
    /// Bundle identifier of the editor used by F4 / Edit; nil picks the first installed
    /// of VS Code, Sublime Text, BBEdit, TextEdit.
    var editorBundleID: String? {
        didSet { UserDefaults.standard.set(editorBundleID, forKey: "editorBundleID") }
    }

    private init() {
        let defaults = UserDefaults.standard
        calculateFolderSizes = defaults.bool(forKey: "calculateFolderSizes")
        listThumbnails = defaults.bool(forKey: "listThumbnails")
        hoverPreview = defaults.object(forKey: "hoverPreview") as? Bool ?? true
        showFunctionKeyBar = defaults.object(forKey: "showFunctionKeyBar") as? Bool ?? true
        editorBundleID = defaults.string(forKey: "editorBundleID")
    }
}
