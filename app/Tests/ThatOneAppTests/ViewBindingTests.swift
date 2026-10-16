import XCTest
@testable import ThatOneApp

@MainActor
final class ViewBindingTests: XCTestCase {
    /// The bindings the views use must trigger searches (a key-path binding from `$model.query` did not).
    func testBindingsTriggerSearches() async {
        let engine = FakeSearching()
        let model = SearchModel(engine: engine, actions: FakeActions(), debounce: .milliseconds(10), limit: 30, home: "/h")
        model.queryBinding.wrappedValue = "bhoomi"
        let typed = await eventually { engine.specs.contains { $0.query == "bhoomi" } }
        XCTAssertTrue(typed)
        model.kindBinding.wrappedValue = .image
        model.folderBinding.wrappedValue = "/p"
        let filtered = await eventually { engine.specs.contains { $0.kinds == ["image"] && $0.folder == "/p" } }
        XCTAssertTrue(filtered)
        let big = BigWindowModel(search: model, folders: { [] })
        big.sinceBinding.wrappedValue = .week
        let since = await eventually { engine.specs.contains { $0.since != nil } }
        XCTAssertTrue(since)
    }
}
