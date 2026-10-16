import XCTest
@testable import ThatOneApp

final class WhisperModelLocatorTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func model(_ name: String, under base: URL? = nil) throws -> URL {
        let folder = (base ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)
        return folder
    }

    func testAModelFolderNamedInTheConfigIsUsedAsIs() throws {
        let folder = try model("mine")
        XCTAssertEqual(WhisperModelLocator.find(configured: folder.path, shynRoot: root.appendingPathComponent("none").path)?.standardizedFileURL, folder.standardizedFileURL)
    }

    func testARootIsSearchedTurboFirst() throws {
        let models = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        _ = try model("openai_whisper-small", under: models)
        let turbo = try model("openai_whisper-large-v3_turbo", under: models)
        XCTAssertEqual(WhisperModelLocator.find(configured: root.path, shynRoot: "/nonexistent")?.standardizedFileURL, turbo.standardizedFileURL)
    }

    func testFallsBackToShynsFolderAndReturnsNilWhenNothingIsThere() throws {
        XCTAssertNil(WhisperModelLocator.find(configured: nil, shynRoot: root.path))
        XCTAssertNil(WhisperModelLocator.find(configured: "", shynRoot: root.path))
        let models = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let found = try model("openai_whisper-large-v3", under: models)
        XCTAssertEqual(WhisperModelLocator.find(configured: nil, shynRoot: root.path)?.standardizedFileURL, found.standardizedFileURL)
    }

    func testAFolderWithoutTheEncoderIsNotAModel() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertNil(WhisperModelLocator.find(configured: root.appendingPathComponent("empty").path, shynRoot: "/nonexistent"))
    }
}
