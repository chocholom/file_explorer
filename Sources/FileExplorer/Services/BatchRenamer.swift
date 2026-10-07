import Foundation

enum BatchRenamer {
    enum CaseMode: String, CaseIterable, Identifiable {
        case lowercase = "lowercase"
        case uppercase = "UPPERCASE"
        case titleCase = "Title Case"

        var id: String { rawValue }
    }

    enum Mode {
        case findReplace(find: String, replace: String)
        case numbering(base: String, start: Int, digits: Int)
        case caseChange(CaseMode)
    }

    /// Computes new file names (extension preserved) for the given names, in order.
    static func apply(_ mode: Mode, to names: [String]) -> [String] {
        names.enumerated().map { index, name in
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let newStem: String
            switch mode {
            case .findReplace(let find, let replace):
                newStem = find.isEmpty ? stem : stem.replacingOccurrences(of: find, with: replace)
            case .numbering(let base, let start, let digits):
                let number = String(format: "%0\(max(1, digits))d", start + index)
                newStem = base.isEmpty ? number : "\(base) \(number)"
            case .caseChange(let caseMode):
                switch caseMode {
                case .lowercase: newStem = stem.lowercased()
                case .uppercase: newStem = stem.uppercased()
                case .titleCase: newStem = stem.capitalized
                }
            }
            return ext.isEmpty ? newStem : "\(newStem).\(ext)"
        }
    }
}
