import ThatOneCore
import XCTest
@testable import ThatOneApp

final class FakeSpeech: SpeechEngine {
    var calls = 0
    var result: Result<[TranscriptSegment], Error> = .success([TranscriptSegment(start: 0, end: 2, text: "hello")])
    func transcribe(path: String, maxSeconds: Double, shouldContinue: @escaping () -> Bool) async throws -> [TranscriptSegment] { calls += 1; return try result.get() }
}

final class TranscriberStateTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/x.wav")

    func session(_ speech: FakeSpeech, located: URL? = URL(fileURLWithPath: "/m"), fired: @escaping () -> Void = {}) -> (SpeechSession, () -> (() -> Void)?) {
        var pending: (() -> Void)?
        let s = SpeechSession(locate: { located }, idleSeconds: 120,
                              scheduler: { _, body in pending = body; return DispatchWorkItem {} }, load: { _ in speech })
        return (s, { pending })
    }

    func testLoadsLazilyOnceAndUnloadsWhenTheIdleTimerFires() throws {
        let speech = FakeSpeech()
        let (s, pending) = session(speech)
        XCTAssertEqual(s.loads, 0); XCTAssertFalse(s.isLoaded)
        _ = try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })
        _ = try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })
        XCTAssertEqual(s.loads, 1); XCTAssertEqual(speech.calls, 2); XCTAssertTrue(s.isLoaded)
        pending()?()
        XCTAssertFalse(s.isLoaded); XCTAssertEqual(s.unloads, 1)
        _ = try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })
        XCTAssertEqual(s.loads, 2)
    }

    func testMissingModelIsUnavailableNotFailed() {
        let (s, _) = session(FakeSpeech(), located: nil)
        XCTAssertFalse(s.isAvailable)
        XCTAssertThrowsError(try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })) {
            guard case TranscribeFailure.unavailable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDecodeErrorsBecomeFailedAndInterruptionsPassThrough() {
        struct Boom: Error {}
        let speech = FakeSpeech()
        let (s, _) = session(speech)
        speech.result = .failure(Boom())
        XCTAssertThrowsError(try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })) {
            guard case TranscribeFailure.failed = $0 else { return XCTFail("\($0)") }
        }
        speech.result = .failure(TranscribeFailure.interrupted)
        XCTAssertThrowsError(try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })) { XCTAssertEqual($0 as? TranscribeFailure, .interrupted) }
    }

    func testNonSpeechAnnotationsAreRecognised() {
        for t in ["[MUSIC]", "(applause)", "♪ la la ♪"] { XCTAssertTrue(SpeechText.isNonSpeechAnnotation(t), t) }
        XCTAssertFalse(SpeechText.isNonSpeechAnnotation("hello (world)"))
    }

    func testCallbackKeptPastTheCallIsHarmlessAndSaysStop() throws {
        final class Keeper: SpeechEngine {
            var kept: (() -> Bool)?
            func transcribe(path: String, maxSeconds: Double, shouldContinue: @escaping () -> Bool) async throws -> [TranscriptSegment] { kept = shouldContinue; return [] }
        }
        let keeper = Keeper()
        let s = SpeechSession(locate: { URL(fileURLWithPath: "/m") }, scheduler: { _, _ in DispatchWorkItem {} }, load: { _ in keeper })
        _ = try s.transcribe(url, maxSeconds: 60, shouldContinue: { true })
        XCTAssertEqual(keeper.kept?(), false)          // WhisperKit calling back late must neither crash nor keep going
    }

    func testLoneFillersAreSilenceHallucinations() {
        for t in ["you", "You.", "um", "Um...", "Hmm"] { XCTAssertTrue(SpeechText.isSilenceFiller(t), t) }
        for t in ["you are late", "thank you", "um, the notice period", "yours"] { XCTAssertFalse(SpeechText.isSilenceFiller(t), t) }
    }

    func testAStopOnceMeansTheResultIsInterruptedEvenIfPressureClears() {
        final class Stopper: SpeechEngine {
            func transcribe(path: String, maxSeconds: Double, shouldContinue: @escaping () -> Bool) async throws -> [TranscriptSegment] {
                _ = shouldContinue()                  // pressure: asked to stop
                _ = shouldContinue()                  // and it has cleared again by the time the engine returns
                return [TranscriptSegment(start: 0, end: 3, text: "half of a long recording")]
            }
        }
        var calls = 0
        let s = SpeechSession(locate: { URL(fileURLWithPath: "/m") }, scheduler: { _, _ in DispatchWorkItem {} }, load: { _ in Stopper() })
        XCTAssertThrowsError(try s.transcribe(url, maxSeconds: 60, shouldContinue: { calls += 1; return calls != 1 })) {
            XCTAssertEqual($0 as? TranscribeFailure, .interrupted)
        }
    }

    func testTheCapReachesTheEngine() throws {
        final class Spy: SpeechEngine {
            var seen: Double?
            func transcribe(path: String, maxSeconds: Double, shouldContinue: @escaping () -> Bool) async throws -> [TranscriptSegment] { seen = maxSeconds; return [] }
        }
        let spy = Spy()
        let s = SpeechSession(locate: { URL(fileURLWithPath: "/m") }, scheduler: { _, _ in DispatchWorkItem {} }, load: { _ in spy })
        _ = try s.transcribe(url, maxSeconds: 10_800, shouldContinue: { true })
        XCTAssertEqual(spy.seen, 10_800)
    }

    func testSegmentsAreAnchoredOnTheirFirstWord() {
        let late = SpeechText.segment(text: "x", start: 60, end: 90, words: [(start: 85.2, end: 85.6), (start: 85.6, end: 89.1)])
        XCTAssertEqual(late.start, 85.2); XCTAssertEqual(late.end, 89.1)
        let none = SpeechText.segment(text: "x", start: 60, end: 90, words: [])
        XCTAssertEqual(none.start, 60); XCTAssertEqual(none.end, 90)
        let nonsense = SpeechText.segment(text: "x", start: 60, end: 90, words: [(start: 10, end: 11)])     // words outside the segment are ignored
        XCTAssertEqual(nonsense.start, 60)
    }

    func testMenuShowsMissingModelOnlyWhenAudioIsOnAndModelMissing() {
        var s = HostSnapshot(); s.state = .idle
        func ids() -> [String] { MenuModel.items(for: s, hotKey: .default).map { $0.id } }
        XCTAssertFalse(ids().contains("audio"))
        s.audio = .ready; XCTAssertFalse(ids().contains("audio"))
        s.audio = .modelMissing; XCTAssertTrue(ids().contains("audio"))
    }
}
