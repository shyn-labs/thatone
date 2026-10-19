import Foundation
import ThatOneCore

public protocol Searching: AnyObject {
    func search(_ q: ServiceQuery) throws -> ServiceSearchResult
    func similar(path: String, limit: Int) throws -> ServiceSearchResult
}

extension EngineHost: Searching {}

@MainActor
public final class SearchModel: ObservableObject {
    @Published public var query = "" { didSet { if query != oldValue { changed(debounced: true) } } }
    @Published public var kind: KindFilter = .all { didSet { if kind != oldValue { changed(debounced: false) } } }
    @Published public var folder: String? { didSet { if folder != oldValue { changed(debounced: false) } } }
    @Published public var since: Date? { didSet { if since != oldValue { changed(debounced: false) } } }
    @Published public private(set) var rows: [ResultRow] = []
    @Published public private(set) var selection = 0
    @Published public private(set) var notice: String?
    @Published public private(set) var isSearching = false
    @Published public private(set) var heading: String?
    @Published public var previewVisible = false

    public var onActivated: (() -> Void)?

    private let engine: Searching
    private let actions: FileActioning
    private let debounce: Duration
    private let limit: Int
    private let home: String
    private var generation = 0
    private var task: Task<Void, Never>?
    private var quiet = false          // true while reset() assigns several properties

    public init(engine: Searching, actions: FileActioning, debounce: Duration = .milliseconds(120),
                limit: Int = 30, home: String = NSHomeDirectory()) {
        self.engine = engine
        self.actions = actions
        self.debounce = debounce
        self.limit = limit
        self.home = home
    }

    public var selectedRow: ResultRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    // MARK: searching

    private func changed(debounced: Bool) {
        guard !quiet else { return }
        run(debounced: debounced, similarTo: nil)
    }

    /// Runs the current query now (used when the panel opens).
    public func refresh() { run(debounced: false, similarTo: nil) }

    /// A clean slate for a new visit: empty query, no filters, newest images.
    public func reset() {
        quiet = true
        query = ""; kind = .all; folder = nil; since = nil
        quiet = false
        previewVisible = false
        refresh()
    }

    public func moreLikeSelected() {
        guard let row = selectedRow else { return }
        run(debounced: false, similarTo: row)
    }

    private func run(debounced: Bool, similarTo row: ResultRow?) {
        generation += 1
        let mine = generation
        task?.cancel()
        heading = row.map { "Similar to \($0.name)" }
        isSearching = true
        let spec = ServiceQuery(query: query, kinds: kind.kinds, folder: folder,
                                since: since.map { Int64($0.timeIntervalSince1970) }, limit: limit)
        let wait = debounce
        let engine = engine
        task = Task { [weak self] in
            if debounced && row == nil { try? await Task.sleep(for: wait) }
            if Task.isCancelled { return }
            // The engine blocks (embedding the query can take a moment), so it never runs on the main thread.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ServiceSearchResult, Error> in
                Result { try row.map { try engine.similar(path: $0.path, limit: spec.limit) } ?? engine.search(spec) }
            }.value
            self?.apply(outcome, generation: mine)
        }
    }

    private func apply(_ outcome: Result<ServiceSearchResult, Error>, generation mine: Int) {
        guard mine == generation else { return }              // a newer search superseded this one
        isSearching = false
        switch outcome {
        case .success(let result):
            rows = result.hits.map { ResultRow(hit: $0, home: home) }
            notice = result.notice
        case .failure(let error):
            rows = []
            notice = "Search failed: \(error)"
        }
        selection = 0
    }

    // MARK: selection and commands

    public func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { selection = 0; return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    /// Opens a row (code at its line); a failure shows "Couldn't open <name>" for the panel and the big window alike.
    @discardableResult
    public func open(_ row: ResultRow) -> Bool {
        let opened = actions.open(row.path, kind: row.kind, line: row.line)
        if !opened { notice = "Couldn't open \(row.name)" }
        return opened
    }

    public func perform(_ command: Command) {
        switch command {
        case .up: moveSelection(by: -1)
        case .down: moveSelection(by: 1)
        case .open:
            guard let row = selectedRow else { return }
            if open(row) { onActivated?() }
        case .reveal: selectedRow.map { actions.reveal($0.path) }
        case .copyPath: selectedRow.map { actions.copyPath($0.path) }
        case .moreLike: moreLikeSelected()
        case .preview: previewVisible.toggle()
        case .cycleKind: kind = kind.next()
        case .close: break                                  // the panel handles this one
        }
    }
}
