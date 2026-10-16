import CoreGraphics
import Foundation
@testable import ThatOneCore

final class Harness {
    let dir = TestSupport.tempDir("h")
    let dbPath: String
    let store: Store
    let embedder = FakeEmbedder()
    let queue: JobQueue
    let indexer: Indexer
    private var counter = 0

    init(ocr: @escaping (CGImage) throws -> String = { _ in "" },
         roots: [String] = [], exclusions: Exclusions = Exclusions()) throws {
        dbPath = dir.appendingPathComponent("index.db").path
        store = try Store.open(path: dbPath, key: TestSupport.key, dim: FakeEmbedder.dim)
        queue = JobQueue(store: store)
        indexer = Indexer(store: store, embedder: embedder, workDir: dir.appendingPathComponent("work"),
                          exclusions: exclusions, roots: { roots }, ocr: ocr)
    }

    /// A PNG whose size (and so its bytes) differs on every call.
    @discardableResult
    func image(_ name: String, in folder: URL? = nil, text: String? = nil) throws -> String {
        counter += 1
        let directory = folder ?? dir.appendingPathComponent("pics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try makeImage(width: 200 + counter, height: 100, text: text, at: url)
        return RealPath.of(url.path)
    }

    func drain() throws {
        while true {
            let batch = try queue.claim(limit: 8)
            if batch.isEmpty { break }
            for (path, outcome) in indexer.index(paths: batch) {
                if case .failed(let message) = outcome { try queue.fail(path: path, error: message) }
                else { try queue.complete(path: path) }
            }
        }
    }
}
