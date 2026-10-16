import XCTest
@testable import ThatOneCore

final class SidecarTests: XCTestCase {
    static let python = TestSupport.repoRoot.appendingPathComponent("bakeoff/.venv/bin/python")
    static let fake = TestSupport.repoRoot.appendingPathComponent("bakeoff/tests/fake_worker.py").path

    func client(_ env: [String: String] = [:]) throws -> SidecarClient {
        try SidecarClient(executable: Self.python, arguments: [Self.fake], environment: env)
    }

    func testInfoAndEmbed() throws {
        let c = try client()
        XCTAssertEqual(try c.info(), SidecarClient.Info(model: "fake", dim: 16, modalities: ["text", "image", "audio"]))
        let v = try c.embed(.text, role: .query, inputs: ["red planet", "blue planet"])
        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(v[0].count, 16)
        XCTAssertEqual(v[0].reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
    }

    func testRemoteErrorsKeepWorkerUsable() throws {
        let c = try client()
        XCTAssertThrowsError(try c.embed(.text, role: .document, inputs: ["bad one"])) {
            XCTAssertEqual($0 as? SidecarError, .remote(code: "input_error", message: "bad input"))
        }
        XCTAssertEqual(try c.embed(.text, role: .document, inputs: ["fine"]).count, 1)
    }

    func testWorkerDeathIsReported() throws {
        let c = try client(["FAKE_DIE_AFTER": "1"])
        _ = try c.embed(.text, role: .document, inputs: ["one"])
        XCTAssertThrowsError(try c.embed(.text, role: .document, inputs: ["two"])) {
            guard case .workerExited = $0 as? SidecarError else { return XCTFail("\($0)") }
        }
    }

    func testUnicodeAndQuotedInputsSurvive() throws {
        let c = try client()
        XCTAssertEqual(try c.embed(.text, role: .document, inputs: ["ಕನ್ನಡ ಫೋಲ್ಡರ್ \"quoted\" it's"]).count, 1)
    }

    func testEmbedderRestartsAfterWorkerDeath() throws {
        var launches = 0
        let e = SidecarEmbedder(maxRestarts: 3) {
            launches += 1
            return try SidecarClient(executable: Self.python, arguments: [Self.fake], environment: ["FAKE_DIE_AFTER": "1"])
        }
        XCTAssertEqual(try e.embed(.text, role: .document, inputs: ["a"]).count, 1)
        XCTAssertThrowsError(try e.embed(.text, role: .document, inputs: ["b"]))          // this worker dies
        XCTAssertEqual(try e.embed(.text, role: .document, inputs: ["c"]).count, 1)       // a fresh one answers
        XCTAssertEqual(launches, 2)
    }

    func testEmbedderGivesUpAfterTooManyConsecutiveDeaths() throws {
        let e = SidecarEmbedder(maxRestarts: 2) {   // FAKE_DIE_AFTER=0: every worker dies on its first embed
            try SidecarClient(executable: Self.python, arguments: [Self.fake], environment: ["FAKE_DIE_AFTER": "0"])
        }
        for _ in 0..<3 {
            XCTAssertThrowsError(try e.embed(.text, role: .document, inputs: ["x"])) {
                guard case .workerExited = $0 as? SidecarError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try e.embed(.text, role: .document, inputs: ["x"])) {
            guard case .unavailable = $0 as? SidecarEmbedder.Failure else { return XCTFail("\($0)") }
        }
    }

    func testIsolationFailsOnlyTheBadInput() {
        let fake = FakeEmbedder()
        fake.failWhen = { _, input in input == "poison" }
        let results = embedIsolating(fake, .text, inputs: ["a", "poison", "c"])
        XCTAssertEqual(results.count, 3)
        XCTAssertNotNil(try? results[0].get())
        XCTAssertNil(try? results[1].get())
        XCTAssertNotNil(try? results[2].get())
        XCTAssertEqual(fake.calls.count, 4)   // one batch call, then three single calls
    }

    func testUnsupportedModalityFailsEverythingWithoutRetries() {
        final class Refuses: Embedder {
            var calls = 0
            func info() throws -> SidecarClient.Info { SidecarClient.Info(model: "x", dim: 4, modalities: ["text"]) }
            func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
                calls += 1
                throw SidecarError.remote(code: "unsupported_modality", message: "image")
            }
        }
        let e = Refuses()
        let results = embedIsolating(e, .image, inputs: ["a", "b"])
        XCTAssertTrue(results.allSatisfy { (try? $0.get()) == nil })
        XCTAssertEqual(e.calls, 1)
    }

    func testEmptyInputsMakeNoCalls() {
        let fake = FakeEmbedder()
        XCTAssertTrue(embedIsolating(fake, .text, inputs: []).isEmpty)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testWorkerKilledWhileIdleIsReportedNotFatal() throws {
        let c = try client()
        _ = try c.embed(.text, role: .document, inputs: ["warm up"])
        kill(c.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        while c.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(c.isRunning)
        // writing to the dead worker's pipe must surface as an error, not kill this process with SIGPIPE
        XCTAssertThrowsError(try c.embed(.text, role: .document, inputs: ["after death"])) {
            guard case .workerExited = $0 as? SidecarError else { return XCTFail("\($0)") }
        }
    }

    func testHungWorkerTimesOutAndTheEmbedderRecovers() throws {
        let embedder = SidecarEmbedder(maxRestarts: 3) {
            try SidecarClient(executable: Self.python, arguments: [Self.fake], timeout: 1.0)
        }
        XCTAssertEqual(try embedder.embed(.text, role: .document, inputs: ["fine"]).count, 1)
        let started = Date()
        XCTAssertThrowsError(try embedder.embed(.text, role: .document, inputs: ["hangnow"])) {
            XCTAssertEqual($0 as? SidecarError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertEqual(try embedder.embed(.text, role: .document, inputs: ["fine again"]).count, 1)   // a fresh worker
    }

    func testStrayOutputLineIsMalformedAndTheEmbedderRestarts() throws {
        let embedder = SidecarEmbedder(maxRestarts: 3) { try self.client() }
        XCTAssertThrowsError(try embedder.embed(.text, role: .document, inputs: ["strayline"])) {
            guard case .malformed = $0 as? SidecarError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try embedder.embed(.text, role: .document, inputs: ["clean"]).count, 1)
    }

    func testWorkerDoesNotInheritTheDatabaseKey() throws {
        setenv("THATONE_KEY_HEX", "SECRET-NOT-FOR-CHILDREN", 1)
        defer { unsetenv("THATONE_KEY_HEX") }
        let script = "import os,sys,json; sys.stdin.readline(); "
            + "print(json.dumps({'id':1,'ok':True,'model':os.environ.get('THATONE_KEY_HEX','absent'),'dim':1,'modalities':[]}))"
        let c = try SidecarClient(executable: Self.python, arguments: ["-c", script])
        XCTAssertEqual(try c.info().model, "absent")
    }

    func testAnEmbedderThatGaveUpTriesAgainAfterTheCooldown() throws {
        var healthy = false
        let e = SidecarEmbedder(maxRestarts: 1, cooldown: 0.3) {
            try SidecarClient(executable: Self.python, arguments: [Self.fake], environment: healthy ? [:] : ["FAKE_DIE_AFTER": "0"])
        }
        for _ in 0..<2 { XCTAssertThrowsError(try e.embed(.text, role: .document, inputs: ["x"])) }
        XCTAssertThrowsError(try e.embed(.text, role: .document, inputs: ["x"])) {
            XCTAssertEqual($0 as? SidecarEmbedder.Failure, .unavailable("the embedding worker exited 2 times in a row"))
        }
        healthy = true
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(try e.embed(.text, role: .document, inputs: ["x"]).count, 1)    // not latched forever
    }
}
