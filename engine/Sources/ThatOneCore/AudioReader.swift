import AVFoundation
import Foundation

/// What the reader needs to know about an audio file; faked in tests so long and odd files need no real audio.
public struct AudioProbe {
    public var duration: (URL) throws -> Double
    /// RMS level of each second (at most `seconds` of them).
    public var loudness: (URL, Int) throws -> [Float]
    public init(duration: @escaping (URL) throws -> Double, loudness: @escaping (URL, Int) throws -> [Float]) {
        self.duration = duration; self.loudness = loudness
    }

    /// AVFoundation: mp3, wav, m4a, aac, flac, caf and aiff. Formats it cannot open are reported, not guessed at.
    public static let system = AudioProbe(
        duration: { url in
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0 else { throw ReadFailure.unreadable("not a readable audio file") }
            return Double(file.length) / file.processingFormat.sampleRate
        },
        loudness: { url, seconds in
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let perSecond = AVAudioFrameCount(format.sampleRate)
            guard perSecond > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: perSecond) else { return [] }
            var levels: [Float] = []
            var consumed: AVAudioFramePosition = 0                           // counted here: framePosition is not reliable for every codec
            let channelCount = Int(format.channelCount)
            // AVAudioFile hands back blocks of its own size (not the size asked for), so a second is gathered from several reads.
            while levels.count < seconds, consumed < file.length {
                var sum: Float = 0
                var frames = 0
                while frames < Int(perSecond), consumed < file.length {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(Int(perSecond) - frames))
                    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { consumed = file.length; break }
                    let n = Int(buffer.frameLength)
                    consumed += AVAudioFramePosition(n)
                    frames += n
                    for c in 0..<channelCount { for i in 0..<n { let v = channels[c][i]; sum += v * v } }
                }
                if frames > 0 { levels.append((sum / Float(frames * channelCount)).squareRoot()) }
            }
            return levels
        })
}

/// Audio: a transcript (speech to text) cut into timed chunks, plus 30 s windows that are embedded as sound. The windows
/// are only described here (source and time range); the indexer cuts them to files after the secret gate.
public final class AudioReader: FileReader {
    private let transcriber: Transcriber
    private let probe: AudioProbe
    private let shouldContinue: () -> Bool
    private let maxBytes: Int64

    public init(transcriber: Transcriber, probe: AudioProbe = .system, shouldContinue: @escaping () -> Bool = { true },
                maxBytes: Int64 = ReadLimits.maxAudioBytes) {
        self.maxBytes = maxBytes
        self.transcriber = transcriber
        self.probe = probe
        self.shouldContinue = shouldContinue
    }

    public func read(_ url: URL) throws -> ReadResult {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else { throw ReadFailure.tooLarge(url.lastPathComponent) }
        let duration: Double
        do { duration = try probe.duration(url) } catch { throw ReadFailure.unreadable("cannot read this audio format") }
        guard duration > 0.05 else { throw ReadFailure.empty("no audio") }

        var notes: [String] = []
        let transcribeSeconds = min(Int(duration.rounded(.up)), ReadLimits.maxTranscribeSeconds)
        if Int(duration) > ReadLimits.maxTranscribeSeconds { notes.append("first \(ReadLimits.maxTranscribeSeconds / 3600) hours") }
        let levels: [Float]
        do { levels = try probe.loudness(url, transcribeSeconds) } catch { throw ReadFailure.unreadable("cannot read this audio format") }
        guard !levels.isEmpty else { throw ReadFailure.unreadable("cannot read this audio format") }     // no data is not silence
        func isSilent(_ range: ClosedRange<Double>) -> Bool {
            let from = max(Int(range.lowerBound), 0), to = min(Int(range.upperBound.rounded(.up)), levels.count)
            guard from < to else { return true }
            return levels[from..<to].allSatisfy { $0 < ReadLimits.silenceRMS }
        }
        if isSilent(0...Double(transcribeSeconds)) { throw ReadFailure.empty("silent") }

        let spoken = try transcriber.transcribe(url, maxSeconds: Double(transcribeSeconds), shouldContinue: shouldContinue)
            .filter { $0.start < Double(ReadLimits.maxTranscribeSeconds) }
        var segments = TranscriptChunker.chunks(spoken).map {
            ReadSegment(modality: "text", anchor: TranscriptChunker.anchorJSON(start: $0.start, end: $0.end), text: $0.text)
        }
        let embedEnd = min(duration, Double(ReadLimits.maxEmbedSeconds))
        if duration > Double(ReadLimits.maxEmbedSeconds) { notes.append("sound embedded for the first \(ReadLimits.maxEmbedSeconds / 60) minutes") }
        var start = 0.0
        while start < embedEnd {
            let end = min(start + Double(ReadLimits.windowSeconds), duration)
            if end - start >= 1, !isSilent(start...end) {
                segments.append(ReadSegment(modality: "audio", anchor: TranscriptChunker.anchorJSON(start: start, end: end), text: "",
                                            audioSource: url, audioRange: start...end))
            }
            start += Double(ReadLimits.windowSeconds)
        }
        guard !segments.isEmpty else { throw ReadFailure.empty("no speech or sound found") }
        return ReadResult(segments: segments, note: notes.joined(separator: "; "))
    }
}
