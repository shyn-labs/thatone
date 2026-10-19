import ThatOneCore
import XCTest
@testable import ThatOneApp

final class FakeSearching: Searching {
    private let lock = NSLock()
    private(set) var specs: [ServiceQuery] = []
    private(set) var similarCalls: [String] = []
    var delays: [String: Double] = [:]
    var failure: Error?
    var result: (ServiceQuery) -> ServiceSearchResult = { q in
        ServiceSearchResult(hits: [hit("/pics/\(q.query.isEmpty ? "recent" : q.query).png")], notice: nil)
    }

    static func hit(_ path: String, why: ServiceAnchor? = nil) -> ServiceHit {
        ServiceHit(paths: [path], kind: "image", score: 1, modified: 1_700_000_000, anchors: why.map { [$0] } ?? [])
    }

    func search(_ q: ServiceQuery) throws -> ServiceSearchResult {
        lock.lock(); specs.append(q); let delay = delays[q.query] ?? 0; let failure = self.failure; lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let failure { throw failure }
        return result(q)
    }

    func similar(path: String, limit: Int) throws -> ServiceSearchResult {
        lock.lock(); similarCalls.append(path); lock.unlock()
        return ServiceSearchResult(hits: [Self.hit("/pics/like-\(path.split(separator: "/").last ?? "").png")], notice: nil)
    }
}
private func hit(_ path: String) -> ServiceHit { FakeSearching.hit(path) }

final class FakeActions: FileActioning {
    private(set) var opened: [String] = [], revealed: [String] = [], copied: [String] = []
    private(set) var openedAt: [(kind: String, line: Int?)] = []
    var openSucceeds = true
    func open(_ path: String, kind: String, line: Int?) -> Bool { opened.append(path); openedAt.append((kind, line)); return openSucceeds }
    func reveal(_ path: String) { revealed.append(path) }
    func copyPath(_ path: String) { copied.append(path) }
}

@MainActor
final class SearchModelTests: XCTestCase {
    func make(_ engine: FakeSearching = FakeSearching(), debounce: Duration = .milliseconds(30)) -> (SearchModel, FakeSearching, FakeActions) {
        let actions = FakeActions()
        return (SearchModel(engine: engine, actions: actions, debounce: debounce, limit: 30, home: "/Users/me"), engine, actions)
    }

    private func codeEngine() -> FakeSearching {
        let engine = FakeSearching()
        engine.result = { _ in ServiceSearchResult(hits: [ServiceHit(paths: ["/tmp/r/a.ts"], kind: "code", score: 1, modified: 0, anchors: [
            ServiceAnchor(modality: "text", anchor: #"{"line0":12,"line1":30}"#, text: "x", viaKeyword: true, viaVector: false)])], notice: nil) }
        return engine
    }

    func testOpenPassesKindAndLineAndAFailureShowsANotice() async {
        let (model, _, actions) = make(codeEngine())
        var activated = 0
        model.onActivated = { activated += 1 }
        model.query = "retry"
        let found = await eventually { model.rows.count == 1 }
        XCTAssertTrue(found)
        model.perform(.open)
        XCTAssertEqual(actions.openedAt.first?.kind, "code")
        XCTAssertEqual(actions.openedAt.first?.line, 12)
        XCTAssertEqual(activated, 1)
        actions.openSucceeds = false
        model.perform(.open)
        XCTAssertEqual(model.notice, "Couldn't open a.ts")
        XCTAssertEqual(activated, 1)
    }

    /// The big window opens through the same model path, so its failures show the same notice (and it never dismisses a panel).
    func testOpeningARowFromTheBigWindowPathShowsTheNoticeOnFailure() async {
        let (model, _, actions) = make(codeEngine())
        var activated = 0
        model.onActivated = { activated += 1 }
        model.query = "retry"
        let found = await eventually { model.rows.count == 1 }
        XCTAssertTrue(found)
        let row = model.rows[0]
        model.open(row)
        XCTAssertNil(model.notice)
        XCTAssertEqual(actions.openedAt.first?.line, 12)
        actions.openSucceeds = false
        model.open(row)
        XCTAssertEqual(model.notice, "Couldn't open a.ts")
        XCTAssertEqual(activated, 0)
    }

    func testRefreshBrowsesAndTypingSearches() async {
        let (model, engine, _) = make()
        model.refresh()
        let browsed = await eventually { model.rows.map { $0.path } == ["/pics/recent.png"] }
        XCTAssertTrue(browsed)
        XCTAssertEqual(engine.specs.first, ServiceQuery(query: "", kinds: [], folder: nil, since: nil, limit: 30))
        model.query = "pipe"
        let found = await eventually { model.rows.map { $0.path } == ["/pics/pipe.png"] }
        XCTAssertTrue(found)
    }

    func testOnlyTheLatestQueryRuns() async {
        let (model, engine, _) = make(debounce: .milliseconds(150))
        model.query = "a"; model.query = "ab"; model.query = "abc"
        let done = await eventually { model.rows.map { $0.path } == ["/pics/abc.png"] }
        XCTAssertTrue(done)
        XCTAssertEqual(engine.specs.map { $0.query }, ["abc"])             // the intermediate keystrokes never reached the engine
    }

    func testStaleResultsAreDiscarded() async {
        let engine = FakeSearching()
        engine.delays["slow"] = 0.4
        let (model, _, _) = make(engine, debounce: .milliseconds(5))
        model.query = "slow"
        try? await Task.sleep(nanoseconds: 100_000_000)                    // "slow" is now running in the engine
        model.query = "fast"
        let fast = await eventually { model.rows.map { $0.path } == ["/pics/fast.png"] }
        XCTAssertTrue(fast)
        try? await Task.sleep(nanoseconds: 600_000_000)                    // let "slow" finish
        XCTAssertEqual(model.rows.map { $0.path }, ["/pics/fast.png"])     // and it must not overwrite the newer result
        XCTAssertFalse(model.isSearching)
    }

    func testSelectionMovesAndClamps() async {
        let engine = FakeSearching()
        engine.result = { _ in ServiceSearchResult(hits: (0..<3).map { hit("/pics/\($0).png") }, notice: nil) }
        let (model, _, _) = make(engine)
        model.refresh()
        _ = await eventually { model.rows.count == 3 }
        model.moveSelection(by: 1); model.moveSelection(by: 1); model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 2)
        model.moveSelection(by: -5)
        XCTAssertEqual(model.selection, 0)
        XCTAssertEqual(model.selectedRow?.path, "/pics/0.png")
    }

    func testFiltersSearchImmediatelyWithTheirValues() async {
        let (model, engine, _) = make(debounce: .seconds(5))               // a debounce this long would hide an immediate search
        model.kind = .image
        let kindSearched = await eventually { engine.specs.contains { $0.kinds == ["image"] } }
        XCTAssertTrue(kindSearched)
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        model.folder = "/pics"; model.since = since
        let filtered = await eventually { engine.specs.contains { $0.folder == "/pics" && $0.since == 1_700_000_000 } }
        XCTAssertTrue(filtered)
    }

    func testCycleKindCommandTogglesTheFilter() async {
        let (model, engine, _) = make()
        model.perform(.cycleKind)
        XCTAssertEqual(model.kind, .image)
        model.perform(.cycleKind); model.perform(.cycleKind)
        XCTAssertEqual(model.kind, .document)
        model.perform(.cycleKind)
        XCTAssertEqual(model.kind, .audio)
        model.perform(.cycleKind)
        XCTAssertEqual(model.kind, .video)
        model.perform(.cycleKind)
        XCTAssertEqual(model.kind, .code)
        model.perform(.cycleKind)
        XCTAssertEqual(model.kind, .all)
        let searched = await eventually { engine.specs.last?.kinds == [] }      // the last filter state is what ran
        XCTAssertTrue(searched)
    }

    func testMoreLikeThisUsesSimilarAndSetsAHeading() async {
        let (model, engine, _) = make()
        model.refresh()
        _ = await eventually { !model.rows.isEmpty }
        model.perform(.moreLike)
        let ok = await eventually { model.heading == "Similar to recent.png" && model.rows.first?.path == "/pics/like-recent.png.png" }
        XCTAssertTrue(ok, "\(String(describing: model.heading)) \(model.rows.map { $0.path })")
        XCTAssertEqual(engine.similarCalls, ["/pics/recent.png"])
        model.query = "x"                                                  // typing leaves the similar view
        _ = await eventually { model.heading == nil }
        XCTAssertNil(model.heading)
    }

    func testFailuresBecomeANoticeNotACrash() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let engine = FakeSearching()
        engine.failure = Boom()
        let (model, _, _) = make(engine)
        model.refresh()
        let ok = await eventually { model.notice == "Search failed: boom" }
        XCTAssertTrue(ok, "\(String(describing: model.notice))")
        XCTAssertEqual(model.rows, [])
    }

    func testNoticeFromTheEngineIsShown() async {
        let engine = FakeSearching()
        engine.result = { _ in ServiceSearchResult(hits: [], notice: "Embedding model unavailable; showing keyword matches only.") }
        let (model, _, _) = make(engine)
        model.query = "x"
        let ok = await eventually { model.notice == "Embedding model unavailable; showing keyword matches only." }
        XCTAssertTrue(ok)
    }

    func testActionsReceiveTheSelectedPath() async {
        let (model, _, actions) = make()
        model.refresh()
        _ = await eventually { !model.rows.isEmpty }
        var activated = 0
        model.onActivated = { activated += 1 }
        model.perform(.open); model.perform(.reveal); model.perform(.copyPath)
        XCTAssertEqual(actions.opened, ["/pics/recent.png"])
        XCTAssertEqual(actions.revealed, ["/pics/recent.png"])
        XCTAssertEqual(actions.copied, ["/pics/recent.png"])
        XCTAssertEqual(activated, 1)                                      // only opening closes the panel
        model.perform(.preview)
        XCTAssertTrue(model.previewVisible)
        model.perform(.preview)
        XCTAssertFalse(model.previewVisible)
    }

    func testActionsWithNothingSelectedAreIgnored() {
        let (model, _, actions) = make()
        model.perform(.open); model.perform(.reveal); model.perform(.copyPath); model.perform(.moreLike)
        XCTAssertTrue(actions.opened.isEmpty && actions.revealed.isEmpty && actions.copied.isEmpty)
    }

    func testResetClearsTheQueryAndBrowsesAgain() async {
        let (model, engine, _) = make()
        model.query = "pipe"
        _ = await eventually { engine.specs.contains { $0.query == "pipe" } }
        model.perform(.cycleKind)
        model.reset()
        XCTAssertEqual(model.query, ""); XCTAssertEqual(model.kind, .all); XCTAssertNil(model.heading)
        let browsed = await eventually { model.rows.map { $0.path } == ["/pics/recent.png"] }
        XCTAssertTrue(browsed)
    }
}

final class ResultRowTests: XCTestCase {
    func testWhyIsASnippetForKeywordMatchesVisualForVectorOnlyAndNoneWhenBrowsing() {
        let keyword = ServiceAnchor(modality: "text", anchor: "{}", text: "invoice 4471", viaKeyword: true, viaVector: true)
        let vector = ServiceAnchor(modality: "image", anchor: "{}", text: "", viaKeyword: false, viaVector: true)
        XCTAssertEqual(ResultRow(hit: FakeSearching.hit("/a.png", why: keyword)).why, .snippet("invoice 4471"))
        XCTAssertEqual(ResultRow(hit: FakeSearching.hit("/a.png", why: vector)).why, .visual)
        XCTAssertEqual(ResultRow(hit: FakeSearching.hit("/a.png")).why, .none)
    }

    func testNameFolderAndDate() {
        let row = ResultRow(hit: ServiceHit(paths: ["/Users/me/Pictures/Trips/it's \"x\".png", "/Users/me/Desktop/copy.png"],
                                            kind: "image", score: 1, modified: 1_700_000_000, anchors: []), home: "/Users/me")
        XCTAssertEqual(row.name, "it's \"x\".png")
        XCTAssertEqual(row.folder, "~/Pictures/Trips")
        XCTAssertEqual(row.otherPaths, ["/Users/me/Desktop/copy.png"])
        XCTAssertEqual(row.modified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ResultRow(hit: FakeSearching.hit("/Volumes/Drive/a.png"), home: "/Users/me").folder, "/Volumes/Drive")
    }

    func testPDFRowsCarryTheMatchedPageAndDocumentRowsCarryTheExcerpt() {
        let pdf = ResultRow(hit: ServiceHit(paths: ["/Users/me/Documents/contract.pdf"], kind: "pdf", score: 1, modified: 5, anchors: [
            ServiceAnchor(modality: "text", anchor: #"{"page":7}"#, text: "notice period is thirty days", viaKeyword: true, viaVector: true),
            ServiceAnchor(modality: "text", anchor: #"{"page":7,"part":2}"#, text: "second", viaKeyword: false, viaVector: true),
            ServiceAnchor(modality: "text", anchor: #"{"page":9}"#, text: "later", viaKeyword: false, viaVector: true)]), home: "/Users/me")
        XCTAssertEqual(pdf.page, 7)
        XCTAssertEqual(pdf.chips, ["p. 7", "p. 9"])                                           // duplicates collapse
        XCTAssertEqual(pdf.why, .snippet("notice period is thirty days"))
        let doc = ResultRow(hit: ServiceHit(paths: ["/a/b.docx"], kind: "document", score: 1, modified: 5, anchors: [
            ServiceAnchor(modality: "text", anchor: #"{"part":2,"heading":"Termination"}"#, text: "Either party may terminate", viaKeyword: true, viaVector: false)]))
        XCTAssertNil(doc.page)
        XCTAssertEqual(doc.excerpt, "Either party may terminate")
        XCTAssertEqual(doc.chips, ["§ Termination"])
    }

    func testPhotosRowsShowFilenameAndAppleFolder() {
        let row = ResultRow(hit: ServiceHit(paths: ["photos:9F3C/L0/001/IMG 8481.HEIC"], kind: "image", score: 1, modified: 5, anchors: []), home: "/Users/me")
        XCTAssertEqual(row.name, "IMG 8481.HEIC")
        XCTAssertEqual(row.folder, "Apple Photos")
    }

    func testAnchorChips() throws {
        XCTAssertEqual(AnchorChip.text(from: #"{"page":3}"#), "p. 3")
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":133.5,"t1":160}"#), "02:13")
        XCTAssertEqual(AnchorChip.text(from: #"{"line0":120,"line1":148}"#), "L120–148")
        XCTAssertEqual(AnchorChip.text(from: #"{"heading":"Notice period"}"#), "§ Notice period")
        let long = try XCTUnwrap(AnchorChip.text(from: #"{"heading":"ಬೆಂಗಳೂರು \"quoted\" heading that is much too long for a chip"}"#))
        XCTAssertTrue(long.hasPrefix("§ ಬೆಂಗಳೂರು \"quoted\""), long)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 2 + 28)
        XCTAssertEqual(AnchorChip.text(from: #"{"part":3}"#), "part 3")
        XCTAssertEqual(AnchorChip.text(from: #"{"page":4,"part":2}"#), "p. 4")
        XCTAssertEqual(AnchorChip.page(from: #"{"page":4,"part":2}"#), 4)
        XCTAssertNil(AnchorChip.page(from: #"{"part":2}"#))
        XCTAssertNil(AnchorChip.text(from: "{}"))
        XCTAssertNil(AnchorChip.text(from: "not json"))
    }

    func testKindFilterCyclesAndMapsToKinds() {
        XCTAssertEqual(KindFilter.all.next(), .image)
        XCTAssertEqual(KindFilter.image.next(), .pdf)
        XCTAssertEqual(KindFilter.pdf.next(), .document)
        XCTAssertEqual(KindFilter.document.next(), .audio)
        XCTAssertEqual(KindFilter.audio.next(), .video)
        XCTAssertEqual(KindFilter.video.next(), .code)
        XCTAssertEqual(KindFilter.code.next(), .all)
        XCTAssertEqual(KindFilter.video.kinds, ["video"])
        XCTAssertEqual(KindFilter.audio.kinds, ["audio"])
        XCTAssertEqual(KindFilter.all.kinds, [])
        XCTAssertEqual(KindFilter.pdf.kinds, ["pdf"])
        XCTAssertEqual(KindFilter.document.kinds, ["document"])
        XCTAssertEqual(KindFilter.allCases.map { $0.title }, ["All", "Images", "PDFs", "Documents", "Audio", "Video", "Code"])
    }
}
