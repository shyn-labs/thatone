import Foundation
import ThatOneCore
import WhisperKit

/// The real speech model. Settings follow what shyn learned the hard way: downloads off (a transcriber that promises to
/// stay on the machine must never ask a model hub anything), the whole file decoded without VAD chunking (which
/// returned zero segments on real audio), four decoder workers (each carries its own cache on a ~3 GB model), and
/// language auto-detection (Kannada, Hindi and English all work).
final class WhisperKitEngine: SpeechEngine {
    private let pipe: WhisperKit

    static func load(folder: URL) async throws -> WhisperKitEngine {
        let pipe = try await WhisperKit(WhisperKitConfig(model: folder.lastPathComponent, downloadBase: folder.deletingLastPathComponent(),
                                                         modelFolder: folder.path, download: false))
        return WhisperKitEngine(pipe: pipe)
    }

    private init(pipe: WhisperKit) { self.pipe = pipe }

    func transcribe(path: String, maxSeconds: Double, shouldContinue: @escaping () -> Bool) async throws -> [TranscriptSegment] {
        var options = DecodingOptions(task: .transcribe, skipSpecialTokens: true)
        options.concurrentWorkerCount = 4
        options.wordTimestamps = true            // a segment's own start can sit tens of seconds before the first word after a silence
        let callback: TranscriptionCallback = { _ in shouldContinue() ? nil : false }       // false asks WhisperKit to stop
        // Only the first `maxSeconds` are decoded (a ten-hour file must not be read whole to be cut afterwards).
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path, endTime: maxSeconds)
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options, callback: callback)
        guard shouldContinue() else { throw TranscribeFailure.interrupted }
        return results.flatMap { $0.segments }.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !SpeechText.isNonSpeechAnnotation(text), !SpeechText.isSilenceFiller(text) else { return nil }
            return SpeechText.segment(text: text, start: Double(segment.start), end: Double(segment.end),
                                      words: (segment.words ?? []).map { (start: Double($0.start), end: Double($0.end)) })
        }
    }
}

public enum SpeechText {
    /// A lone "you" or "um" is what Whisper writes for a stretch of silence or a tone, not something anyone said. It also
    /// pulls a chunk's start back to the middle of the silence, so the time chip would point at the wrong place.
    public static func isSilenceFiller(_ text: String) -> Bool {
        let letters = text.lowercased().filter { $0.isLetter }
        return ["you", "um", "uh", "hmm", "mm", "mhm", "bye"].contains(letters)
    }


    /// A segment anchored on its words when it has them: Whisper can report a segment as starting at the top of its
    /// 30-second window although the first word comes much later, so a hit would play from the wrong place.
    public static func segment(text: String, start: Double, end: Double, words: [(start: Double, end: Double)]) -> TranscriptSegment {
        guard let first = words.first, let last = words.last, first.start >= start - 0.5, last.end >= first.start else {
            return TranscriptSegment(start: start, end: max(end, start), text: text)
        }
        return TranscriptSegment(start: first.start, end: max(last.end, first.start), text: text)
    }

    /// "[MUSIC]", "(applause)", "♪ ♪": Whisper's labels for sounds, which are not words anyone said.
    public static func isNonSpeechAnnotation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }
        if t.hasPrefix("(") && t.hasSuffix(")") { return true }
        if t.hasPrefix("♪") || t.hasSuffix("♪") { return true }
        return false
    }
}

extension SpeechSession {
    /// The transcriber the app uses: WhisperKit, model found through `WhisperModelLocator`.
    public static func whisperKit(configuredFolder: @escaping () -> String?) -> SpeechSession {
        SpeechSession(locate: { WhisperModelLocator.find(configured: configuredFolder()) }, load: { try await WhisperKitEngine.load(folder: $0) })
    }
}
