import ThatOneCore
import XCTest
@testable import ThatOneApp

@MainActor
final class BigWindowModelTests: XCTestCase {
    func row(_ path: String, modified: Int64, score: Double = 1) -> ResultRow {
        ResultRow(hit: ServiceHit(paths: [path], kind: "image", score: score, modified: modified, anchors: []), home: "/h")
    }

    func testSortOrders() {
        let rows = [row("/p/b.png", modified: 20), row("/p/A.png", modified: 10), row("/p/c.png", modified: 30)]
        XCTAssertEqual(SortOrder.sort(rows, by: .relevance, hasQuery: true).map { $0.name }, ["b.png", "A.png", "c.png"])
        XCTAssertEqual(SortOrder.sort(rows, by: .newest, hasQuery: true).map { $0.name }, ["c.png", "b.png", "A.png"])
        XCTAssertEqual(SortOrder.sort(rows, by: .oldest, hasQuery: true).map { $0.name }, ["A.png", "b.png", "c.png"])
        XCTAssertEqual(SortOrder.sort(rows, by: .name, hasQuery: true).map { $0.name }, ["A.png", "b.png", "c.png"])
    }

    func testRelevanceWithoutAQueryFallsBackToNewest() {
        let rows = [row("/p/a.png", modified: 10), row("/p/b.png", modified: 20)]
        XCTAssertEqual(SortOrder.sort(rows, by: .relevance, hasQuery: false).map { $0.name }, ["b.png", "a.png"])
    }

    func testSinceFilterDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(SinceFilter.anytime.date(now: now))
        XCTAssertEqual(SinceFilter.week.date(now: now), now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(SinceFilter.month.date(now: now), now.addingTimeInterval(-30 * 86400))
        XCTAssertEqual(SinceFilter.year.date(now: now), now.addingTimeInterval(-365 * 86400))
    }

    func testModelAppliesTheSinceFilterToTheSearch() async {
        let engine = FakeSearching()
        let search = SearchModel(engine: engine, actions: FakeActions(), debounce: .milliseconds(5), limit: 30, home: "/h")
        let model = BigWindowModel(search: search, folders: { ["/p"] })
        model.since = .week
        let ok = await eventually { engine.specs.contains { $0.since != nil } }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.folders, ["/p"])
    }

    func testVisibleRowsFollowTheEffectiveOrder() async {
        let engine = FakeSearching()
        engine.result = { _ in ServiceSearchResult(hits: [
            ServiceHit(paths: ["/p/b.png"], kind: "image", score: 2, modified: 20, anchors: []),
            ServiceHit(paths: ["/p/a.png"], kind: "image", score: 1, modified: 10, anchors: [])], notice: nil) }
        let search = SearchModel(engine: engine, actions: FakeActions(), debounce: .milliseconds(5), limit: 30, home: "/h")
        let model = BigWindowModel(search: search, folders: { [] })
        search.refresh()
        _ = await eventually { !search.rows.isEmpty }
        XCTAssertEqual(model.visibleRows.map { $0.name }, ["b.png", "a.png"])      // browsing: automatic = newest
        model.sortOrder = .name
        XCTAssertEqual(model.visibleRows.map { $0.name }, ["a.png", "b.png"])
    }
}
