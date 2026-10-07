import Foundation

enum DateFilter: String, CaseIterable, Identifiable {
    case any = "Any Time"
    case today = "Today"
    case week = "Last 7 Days"
    case month = "Last 30 Days"
    case year = "This Year"
    case older = "Older Than a Year"

    var id: String { rawValue }

    func matches(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .any:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .week:
            return date >= now.addingTimeInterval(-7 * 86400)
        case .month:
            return date >= now.addingTimeInterval(-30 * 86400)
        case .year:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
        case .older:
            return date < now.addingTimeInterval(-365 * 86400)
        }
    }
}

enum SizeFilter: String, CaseIterable, Identifiable {
    case any = "Any Size"
    case under1MB = "< 1 MB"
    case oneTo100MB = "1–100 MB"
    case over100MB = "> 100 MB"
    case over1GB = "> 1 GB"

    var id: String { rawValue }

    /// Folders always pass; their reported size is meaningless.
    func matches(_ size: Int64) -> Bool {
        switch self {
        case .any: return true
        case .under1MB: return size < 1_000_000
        case .oneTo100MB: return (1_000_000..<100_000_000).contains(size)
        case .over100MB: return size >= 100_000_000
        case .over1GB: return size >= 1_000_000_000
        }
    }
}
