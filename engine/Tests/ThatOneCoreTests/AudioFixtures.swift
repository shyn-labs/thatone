import AVFoundation
import Foundation
import XCTest
@testable import ThatOneCore

enum AudioFixtures {
    /// Writes a WAV: a sine tone of the given loudness for `seconds` (amplitude 0 = silence).
    static func wav(seconds: Double, amplitude: Float = 0.3, sampleRate: Double = 16000, channels: AVAudioChannelCount = 1,
                    name: String = "a.wav") -> URL {
        let url = TestSupport.tempDir("audio").appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let file = try! AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate)) }
        }
        try! file.write(from: buffer)
        return url
    }

    /// Loud for the first `loud` seconds, then silent until `total`.
    static func wavLoudThenSilent(loud: Double, total: Double) -> URL {
        let url = TestSupport.tempDir("audio").appendingPathComponent("mixed.wav")
        let rate = 16000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try! AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(total * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Double(i) / rate < loud ? 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) : 0 }
        try! file.write(from: buffer)
        return url
    }
}

/// A transcriber that returns what it is given (or throws), and records how it was called.
final class FakeTranscriber: Transcriber {
    var isAvailable = true
    var segments: [TranscriptSegment] = []
    var failure: Error?
    var onTranscribe: (() -> Void)?
    var onReturn: (() -> Void)?
    private(set) var lastMaxSeconds: Double?
    private(set) var calls: [URL] = []

    func transcribe(_ url: URL, maxSeconds: Double, shouldContinue: () -> Bool) throws -> [TranscriptSegment] {
        calls.append(url)
        lastMaxSeconds = maxSeconds
        onTranscribe?()
        if !shouldContinue() { throw TranscribeFailure.interrupted }
        if let failure { throw failure }
        onReturn?()
        return segments
    }
}

/// Fake probe: a fixed duration and per-second loudness pattern, no real audio needed.
func fakeProbe(duration: Double, loudness: @escaping (Int) -> Float = { _ in 0.2 }) -> AudioProbe {
    AudioProbe(duration: { _ in duration }, loudness: { _, seconds in (0..<seconds).map(loudness) })
}
