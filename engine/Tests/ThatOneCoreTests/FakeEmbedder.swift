import Foundation
@testable import ThatOneCore

/// Deterministic in-process embedder: text → hashed bag of words, image → seeded by the file's bytes.
final class FakeEmbedder: Embedder {
    static let dim = 16
    var calls: [(EmbedModality, EmbedRole, [String])] = []
    var infoCalls = 0
    var failWhen: (EmbedModality, String) -> Bool = { _, _ in false }

    func info() throws -> SidecarClient.Info {
        infoCalls += 1
        return SidecarClient.Info(model: "fake", dim: Self.dim, modalities: ["text", "image"])
    }

    var failure: Error?
    var onEmbed: (() -> Void)?
    /// Image vectors chosen by the test from the file's contents (video tests write a label instead of real JPEG bytes).
    var imageVector: ((String) -> [Float])?

    func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
        calls.append((modality, role, inputs))
        onEmbed?()
        if let failure { throw failure }
        for input in inputs where failWhen(modality, input) {
            throw SidecarError.remote(code: "input_error", message: "forced failure for \(input)")
        }
        return inputs.map { input in
            if modality == .image {
                let bytes = FileManager.default.contents(atPath: input) ?? Data(input.utf8)
                if let imageVector { return imageVector(String(decoding: bytes, as: UTF8.self)) }
                return Self.vector(for: "img\(bytes.hashValue)")
            }
            return Self.vector(for: input)
        }
    }

    static func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0.01, count: dim)
        for word in Tokens.words(text) {
            var h: UInt64 = 1469598103934665603                      // FNV-1a
            for b in word.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dim))] += 1
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    func callCount(_ modality: EmbedModality) -> Int { calls.filter { $0.0 == modality }.count }
}
