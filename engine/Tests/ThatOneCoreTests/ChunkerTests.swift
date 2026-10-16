import XCTest
@testable import ThatOneCore

final class ChunkerTests: XCTestCase {
    func testShortParagraphsPackTogetherAndStayWhole() {
        let text = "First paragraph here.\n\nSecond paragraph here.\n\nThird one."
        let chunks = TextChunker.chunks(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "First paragraph here.\n\nSecond paragraph here.\n\nThird one.")
        XCTAssertEqual(chunks[0].index, 0)
        XCTAssertNil(chunks[0].heading)
    }

    func testChunksNeverExceedTheMaximumAndNeverAreEmpty() {
        let sentence = "The notice period is thirty days from the date of written notice. "
        let long = String(repeating: sentence, count: 200)                        // one 13,000-character paragraph
        let chunks = TextChunker.chunks(long + "\n\n\n\n   \n\nTail paragraph.")
        XCTAssertGreaterThan(chunks.count, 5)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.text.count, 1800)
            XCTAssertFalse(c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(chunks.map { $0.index }, Array(0..<chunks.count))
        XCTAssertTrue(chunks.last!.text.contains("Tail paragraph."))
    }

    func testAnOversizedSentenceWithoutPunctuationIsCutOnWordsThenHard() {
        let words = String(repeating: "alpha beta ", count: 400)                  // 4,400 characters, no sentence end
        for c in TextChunker.chunks(words) { XCTAssertLessThanOrEqual(c.text.count, 1800) }
        let solid = String(repeating: "x", count: 5000)                           // no whitespace at all
        let hard = TextChunker.chunks(solid)
        XCTAssertEqual(hard.map { $0.text.count }.reduce(0, +), 5000)
        for c in hard { XCTAssertLessThanOrEqual(c.text.count, 1800) }
    }

    func testHeadingsStartNewChunksAndLabelThem() {
        let body = String(repeating: "Body text of the section goes on for a while. ", count: 4)
        let text = "Notice period\n\n\(body)\n\nTermination\n\n\(body)"
        let chunks = TextChunker.chunks(text)
        XCTAssertEqual(chunks.map { $0.heading }, ["Notice period", "Termination"])
        XCTAssertTrue(chunks[0].text.hasPrefix("Notice period"))                   // the heading words are searchable with their section
        XCTAssertFalse(chunks[0].text.contains("Termination"))
    }

    func testSentencesAndLongLinesAreNotHeadings() {
        let body = String(repeating: "Body text of the section goes on for a while. ", count: 4)
        XCTAssertNil(TextChunker.chunks("This is a sentence.\n\n\(body)").first?.heading)
        XCTAssertNil(TextChunker.chunks("A line without period but followed by almost nothing\n\nshort").first?.heading)
        XCTAssertNil(TextChunker.chunks(String(repeating: "word ", count: 30) + "\n\n\(body)\(body)\(body)").first?.heading)   // over 80 characters
    }

    func testIndicTextIsNeverCutInsideAGraphemeCluster() {
        let kannada = String(repeating: "ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ ಇಂದು ಚೆನ್ನಾಗಿದೆ. ", count: 120)
        let chunks = TextChunker.chunks(kannada)
        XCTAssertGreaterThan(chunks.count, 1)
        let rejoined = chunks.map { $0.text }.joined(separator: " ")
        for scalarWord in ["ಬೆಂಗಳೂರು", "ಹವಾಮಾನ", "ಚೆನ್ನಾಗಿದೆ"] { XCTAssertTrue(rejoined.contains(scalarWord)) }
        XCTAssertFalse(rejoined.unicodeScalars.contains("\u{FFFD}"))
        for c in chunks { XCTAssertEqual(c.text, String(c.text.unicodeScalars)) }                   // valid, whole scalars
    }

    func testEmptyAndWhitespaceTextGiveNoChunks() {
        XCTAssertEqual(TextChunker.chunks(""), [])
        XCTAssertEqual(TextChunker.chunks("  \n\n \t \n"), [])
    }

    func testWindowsLineEndingsAreNormalised() {
        XCTAssertEqual(TextChunker.chunks("one\r\n\r\ntwo\rthree").first?.text, "one\n\ntwo\nthree")
    }

    func testAnchorJSON() throws {
        XCTAssertEqual(TextChunker.anchorJSON(page: 4, part: nil, heading: nil), #"{"page":4}"#)
        XCTAssertEqual(TextChunker.anchorJSON(page: 4, part: 2, heading: nil), #"{"page":4,"part":2}"#)
        XCTAssertEqual(TextChunker.anchorJSON(page: nil, part: 3, heading: nil), #"{"part":3}"#)
        XCTAssertEqual(TextChunker.anchorJSON(page: nil, part: nil, heading: nil), "{}")
        let hostile = "He said \"stop\"\n\u{7}\\ ಕನ್ನಡ"
        let json = TextChunker.anchorJSON(page: nil, part: nil, heading: hostile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["heading"] as? String, hostile)                      // escaped, valid, lossless
        let long = TextChunker.anchorJSON(page: nil, part: nil, heading: String(repeating: "h", count: 500))
        XCTAssertLessThan(long.count, 200)
    }
}
