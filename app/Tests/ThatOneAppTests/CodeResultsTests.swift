import ThatOneCore
import XCTest
@testable import ThatOneApp

final class CodeResultsTests: XCTestCase {
    func hit(_ anchor: String, text: String = "src/a.ts · retry · L3–14\nfunction retry() {") -> ServiceHit {
        ServiceHit(paths: ["/tmp/r/src/a.ts"], kind: "code", score: 1, modified: 0,
                   anchors: [ServiceAnchor(modality: "text", anchor: anchor, text: text, viaKeyword: true, viaVector: true)])
    }

    func testLineAnchorGivesChipLineAndRange() {
        let row = ResultRow(hit: hit(#"{"line0":3,"line1":14,"symbol":"retry"}"#))
        XCTAssertEqual(row.chips, ["L3–14"])
        XCTAssertEqual(row.line, 3)
        XCTAssertEqual(row.lineEnd, 14)
        XCTAssertNil(ResultRow(hit: hit(#"{"page":2}"#)).line)
        XCTAssertNil(AnchorChip.lineRange(from: "not json"))
        XCTAssertEqual(AnchorChip.lineRange(from: #"{"line0":5,"line1":9}"#)?.first, 5)
    }

    func testCodeSwitchFilterIconAndMenu() {
        let sw = KindSwitch.all.first { $0.kind == "code" }
        XCTAssertEqual(sw?.title, "Code")
        XCTAssertEqual(sw?.note, "Respects .gitignore; hidden from normal searches unless you pick Code")
        XCTAssertEqual(KindFilter.video.next(), .code)
        XCTAssertEqual(KindFilter.code.next(), .all)
        XCTAssertEqual(KindFilter.code.kinds, ["code"])
        XCTAssertEqual(KindFilter.code.title, "Code")
        XCTAssertEqual(KindIcon.name(for: "code"), "chevron.left.forwardslash.chevron.right")
        var s = HostSnapshot(); s.state = .idle
        func title() -> String? { MenuModel.items(for: s, hotKey: .default).first { $0.id == "code" }?.title }
        XCTAssertNil(title())
        s.kinds = ["code": 1]; XCTAssertEqual(title(), "1 code file")
        s.kinds = ["code": 12]; XCTAssertEqual(title(), "12 code files")
    }

    func testExcerptReadsTheChunkLinesNumberedAsTheEngineCountsThem() throws {
        let url = Fixtures.tempDir("code").appendingPathComponent("a.swift")
        try Data("one\r\ntwo\r\nthree\r\nfour\r\n".utf8).write(to: url)
        XCTAssertEqual(CodeExcerpt.lines(path: url.path, from: 2, to: 3), [CodeLine(number: 2, text: "two"), CodeLine(number: 3, text: "three")])
        XCTAssertEqual(CodeExcerpt.lines(path: url.path, from: 3, to: 99)?.map { $0.number }, [3, 4])
        XCTAssertNil(CodeExcerpt.lines(path: url.path, from: 9, to: 12))
        XCTAssertNil(CodeExcerpt.lines(path: url.path + ".gone", from: 1, to: 2))
        XCTAssertEqual(CodeExcerpt.fallback("hdr · x · L1–2\nlet a = 1"), "let a = 1")
        let long = Fixtures.tempDir("code").appendingPathComponent("b.swift")
        try Data((1...200).map { "l\($0)" }.joined(separator: "\n").utf8).write(to: long)
        XCTAssertEqual(CodeExcerpt.lines(path: long.path, from: 10, to: 200)?.count, 80)
    }
}
