import Combine
import Foundation

public enum SortOrder: String, CaseIterable {
    case relevance, newest, oldest, name

    public static func sort(_ rows: [ResultRow], by order: SortOrder, hasQuery: Bool) -> [ResultRow] {
        let effective = (order == .relevance && !hasQuery) ? SortOrder.newest : order
        switch effective {
        case .relevance: return rows
        case .newest: return rows.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .oldest: return rows.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        case .name: return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

public enum SinceFilter: String, CaseIterable {
    case anytime, week, month, year

    public var title: String {
        switch self { case .anytime: "Any time"; case .week: "Past week"; case .month: "Past month"; case .year: "Past year" }
    }

    public func date(now: Date = Date()) -> Date? {
        switch self {
        case .anytime: nil
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        case .year: now.addingTimeInterval(-365 * 86400)
        }
    }
}

@MainActor
public final class BigWindowModel: ObservableObject {
    public var search: SearchModel
    @Published public var sortOrder: SortOrder?                      // nil = automatic
    @Published public var since: SinceFilter = .anytime { didSet { search.since = since.date() } }
    private let folderSource: () -> [String]
    private var forwarding: AnyCancellable?

    public init(search: SearchModel, folders: @escaping () -> [String]) {
        self.search = search
        self.folderSource = folders
        forwarding = search.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public var folders: [String] { folderSource() }

    public var visibleRows: [ResultRow] {
        SortOrder.sort(search.rows, by: sortOrder ?? .relevance, hasQuery: !search.query.isEmpty)
    }
}
