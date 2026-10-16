import Foundation

public struct TranscriptSegment: Equatable {
    public var start: Double          // seconds from the start of the file
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public enum TranscribeFailure: Error, Equatable {
    case unavailable(String)          // no model, or it could not be loaded: wait and try again later
    case interrupted                  // asked to stop (paused, low memory): wait and try again later
    case failed(String)               // this file could not be transcribed
}

/// Speech to text. The app supplies the real one (WhisperKit); the engine is tested against a fake. Never called on
/// the main thread.
public protocol Transcriber: AnyObject {
    /// True when the model is present and loadable.
    var isAvailable: Bool { get }
    /// Blocking. Reads at most the first `maxSeconds` of the file (it must not decode more than that). Checks
    /// `shouldContinue` between pieces so a pause or memory pressure can interrupt a long file.
    func transcribe(_ url: URL, maxSeconds: Double, shouldContinue: () -> Bool) throws -> [TranscriptSegment]
}

public enum TranscriptChunker {
    /// Groups consecutive segments into pieces of about `target` seconds (and at most `maxChars` characters) so a hit
    /// points at a stretch of speech, not a single phrase. Empty text is dropped; spacing is normalised.
    public static func chunks(_ segments: [TranscriptSegment], target: Double = 30, maxChars: Int = 1800, maxGap: Double = ReadLimits.chunkGapSeconds) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: TranscriptSegment?
        func flush() { if let c = current { out.append(c) }; current = nil }
        for raw in segments.sorted(by: { $0.start < $1.start }) {
            let text = raw.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let segment = TranscriptSegment(start: raw.start, end: max(raw.end, raw.start), text: text)
            if var c = current {
                let wouldBe = segment.end - c.start
                if wouldBe > target * 1.5 || segment.start - c.end > maxGap || c.text.count + segment.text.count + 1 > maxChars { flush(); current = segment; continue }
                c.end = segment.end
                c.text += " " + segment.text
                current = c
                if c.end - c.start >= target { flush() }
            } else {
                current = segment
                if segment.end - segment.start >= target { flush() }
            }
        }
        flush()
        // One enormous segment (no timing inside it) is split on text boundaries but keeps the same time range.
        return out.flatMap { chunk -> [TranscriptSegment] in
            guard chunk.text.count > maxChars else { return [chunk] }
            return TextChunker.chunks(chunk.text, target: maxChars * 2 / 3, maxLength: maxChars).map {
                TranscriptSegment(start: chunk.start, end: chunk.end, text: $0.text)
            }
        }
    }

    /// `{"t0":12.5,"t1":41}`: seconds, to a tenth.
    public static func anchorJSON(start: Double, end: Double) -> String {
        func rounded(_ v: Double) -> Double { (max(v, 0) * 10).rounded() / 10 }
        let object: [String: Any] = ["t0": rounded(start), "t1": rounded(end)]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
