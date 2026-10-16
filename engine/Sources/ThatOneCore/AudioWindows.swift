import AVFoundation
import Foundation

/// Cuts a stretch of an audio file into a small 16 kHz mono WAV, which is what the embedding worker expects. Done in
/// process with AVFoundation (no external tool), and only after the secret gate: this writes a copy of the sound.
public enum AudioWindows {
    public static let sampleRate = 16000.0

    public static func extract(source: URL, range: ClosedRange<Double>, to destination: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let inFormat = file.processingFormat
        let rate = inFormat.sampleRate
        guard rate > 0, range.upperBound > range.lowerBound else { throw ReadFailure.unreadable("empty audio window") }
        let startFrame = AVAudioFramePosition(range.lowerBound * rate)
        guard startFrame < file.length else { throw ReadFailure.unreadable("window starts after the end of the audio") }
        let wanted = AVAudioFrameCount(min(AVAudioFramePosition((range.upperBound - range.lowerBound) * rate), file.length - startFrame))
        file.framePosition = startFrame

        guard let window = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: wanted) else { throw ReadFailure.tooLarge("audio window") }
        guard let block = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 32768) else { throw ReadFailure.tooLarge("audio window") }
        var filled: AVAudioFrameCount = 0
        while filled < wanted {
            try file.read(into: block, frameCount: min(32768, wanted - filled))
            guard block.frameLength > 0 else { break }
            for channel in 0..<Int(inFormat.channelCount) {
                memcpy(window.floatChannelData![channel] + Int(filled), block.floatChannelData![channel], Int(block.frameLength) * MemoryLayout<Float>.size)
            }
            filled += block.frameLength
        }
        window.frameLength = filled
        guard filled > 0 else { throw ReadFailure.unreadable("no audio in the window") }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw ReadFailure.unreadable("cannot convert this audio") }
        let outCapacity = AVAudioFrameCount(Double(filled) / rate * sampleRate) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { throw ReadFailure.tooLarge("audio window") }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return window
        }
        if status == .error || converted.frameLength == 0 { throw ReadFailure.unreadable("cannot convert this audio") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try AVAudioFile(forWriting: destination, settings: outFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: converted)
    }
}
