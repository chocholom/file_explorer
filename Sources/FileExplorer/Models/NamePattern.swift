import Foundation

/// Wildcard name matching for "Select by pattern" (Total Commander's Num+ / Num−).
///
/// Several patterns can be separated by `;` or whitespace: `*.jpg; *.png`.
/// A pattern without wildcards matches as a substring, so typing `report` selects
/// everything containing "report". Matching is case-insensitive.
enum NamePattern {
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let hasWildcard = pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
            let effective = hasWildcard ? pattern : "*\(pattern)*"
            return fnmatch(effective, name, FNM_CASEFOLD) == 0
        }
    }

    static func matches(_ name: String, text: String) -> Bool {
        matches(name, patterns: parse(text))
    }
}
