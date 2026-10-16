import XCTest
@testable import ThatOneCore

final class TranscriptChunkerTests: XCTestCase {
    func seg(_ s: Double, _ e: Double, _ t: String) -> TranscriptSegment { TranscriptSegment(start: s, end: e, text: t) }

    func testShortPhrasesAreGroupedIntoAboutThirtySeconds() {
        let phrases = (0..<12).map { seg(Double($0) * 5, Double($0) * 5 + 4.5, "phrase number \($0)") }     // 60 s of speech
        let chunks = TranscriptChunker.chunks(phrases)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertGreaterThanOrEqual(chunks[0].end - chunks[0].start, 30)
        XCTAssertTrue(chunks[0].text.hasPrefix("phrase number 0 phrase number 1"))
        XCTAssertEqual(chunks.map { $0.text }.joined(separator: " ").components(separatedBy: "phrase number").count - 1, 12)   // nothing lost
    }

    func testOrderIsRestoredAndEmptyTextIsDropped() {
        let chunks = TranscriptChunker.chunks([seg(10, 12, "second"), seg(0, 2, "  first \n"), seg(5, 6, "   "), seg(6, 7, "")])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "first second")
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].end, 12)
    }

    func testALongPauseStartsANewChunk() {
        let chunks = TranscriptChunker.chunks([seg(0, 4, "before the pause"), seg(300, 304, "after the pause")])
        XCTAssertEqual(chunks.map { $0.text }, ["before the pause", "after the pause"])
        XCTAssertEqual(chunks.map { $0.start }, [0, 300])
    }

    func testOneEnormousSegmentIsSplitOnTextButKeepsItsTimeRange() {
        let text = String(repeating: "alpha bravo charlie delta echo foxtrot. ", count: 200)          // 8,000 characters in one segment
        let chunks = TranscriptChunker.chunks([seg(10, 400, text)])
        XCTAssertGreaterThan(chunks.count, 3)
        for c in chunks { XCTAssertLessThanOrEqual(c.text.count, 1800); XCTAssertEqual(c.start, 10); XCTAssertEqual(c.end, 400) }
    }

    func testKannadaAndHindiTextPassesThroughUnchanged() {
        let chunks = TranscriptChunker.chunks([seg(0, 5, "ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ"), seg(5, 9, "आज मौसम अच्छा है")])
        XCTAssertEqual(chunks.first?.text, "ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ आज मौसम अच्छा है")
    }

    func testAnchorJSONRoundsToATenth() throws {
        XCTAssertEqual(TranscriptChunker.anchorJSON(start: 12.46, end: 41), #"{"t0":12.5,"t1":41}"#)
        XCTAssertEqual(TranscriptChunker.anchorJSON(start: -3, end: 0.04), #"{"t0":0,"t1":0}"#)
    }

    func testEmptyInputGivesNoChunks() { XCTAssertEqual(TranscriptChunker.chunks([]), []) }

    // MARK: silence gaps

    func gateCase() -> [TranscriptSegment] { [seg(0, 4.9, "a"), seg(40.9, 45.0, "b"), seg(81.7, 85.5, "c")] }

    func testPhrasesSeparatedByLongSilenceAreNotMerged() {
        let chunks = TranscriptChunker.chunks(gateCase())
        XCTAssertEqual(chunks.map { $0.text }, ["a", "b", "c"])
        XCTAssertEqual(chunks.map { $0.start }, [0, 40.9, 81.7])
    }

    func testGapBoundaryIsExclusive() {
        XCTAssertEqual(TranscriptChunker.chunks([seg(0, 2, "x"), seg(10, 12, "y")]).count, 1)      // gap exactly 8
        XCTAssertEqual(TranscriptChunker.chunks([seg(0, 2, "x"), seg(10.1, 12, "y")]).count, 2)    // gap 8.1
    }

    func testContinuousSpeechGroupsAsBefore() {
        let segs = (0..<6).map { seg(Double($0) * 12, Double($0) * 12 + 10, "s\($0)") }   // 2 s gaps
        let chunks = TranscriptChunker.chunks(segs)
        XCTAssertEqual(chunks.map { $0.text }, ["s0 s1 s2", "s3 s4 s5"])
        XCTAssertEqual(chunks.map { $0.start }, [0, 36])
        XCTAssertEqual(chunks.map { $0.end }, [34, 70])
    }

    func testInfiniteMaxGapRestoresOldBehaviour() {
        let chunks = TranscriptChunker.chunks(gateCase(), maxGap: .infinity)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].text, "a b")
    }

    func testOverlappingSegmentsNeverSplitOnGap() {
        let chunks = TranscriptChunker.chunks([seg(0, 6, "x"), seg(4, 9, "y"), seg(5, 7, "z")])
        XCTAssertEqual(chunks.map { $0.text }, ["x y z"])
        XCTAssertEqual(chunks[0].end, 7)   // existing behaviour: end follows the last segment
    }
}
