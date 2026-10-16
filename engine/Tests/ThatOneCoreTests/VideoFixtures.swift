import AVFoundation
import CoreVideo
import Foundation
@testable import ThatOneCore

enum VideoFixtures {
    typealias Scene = (seconds: Double, rgb: (UInt8, UInt8, UInt8))

    /// Writes a tiny 64x48 H.264 movie, one flat colour per scene, with an optional mono AAC sine track. `transform` is
    /// stored as the track's preferred transform (a phone held upright stores landscape pixels plus a 90-degree turn).
    /// `marker` puts a small white square in the top-left corner of every frame, so a scene is a picture and not one flat
    /// colour (which the real cutter drops as blank); the centre keeps the scene's colour.
    static func mp4(scenes: [Scene], sine: Bool, name: String = "clip.mp4", transform: CGAffineTransform = .identity,
                    marker: Bool = false) -> URL {
        let url = TestSupport.tempDir("video").appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,      // tagged, so colours read back true
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        vInput.transform = transform
        writer.add(vInput)
        var aInput: AVAssetWriterInput?
        let rate = 44100.0
        if sine {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            writer.add(a); aInput = a
        }
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        let total = scenes.reduce(0) { $0 + $1.seconds }
        let totalAudio = Int(total * rate)
        var audioWritten = 0
        var desc: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        func audioChunk() -> CMSampleBuffer {
            let n = min(4410, totalAudio - audioWritten)
            var samples = [Int16](repeating: 0, count: n)
            for i in 0..<n { samples[i] = Int16(8000 * sin(Double(audioWritten + i) * 2 * .pi * 440 / rate)) }
            var block: CMBlockBuffer?
            let bytes = n * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!,
                sampleCount: n, presentationTimeStamp: CMTime(value: Int64(audioWritten), timescale: Int32(rate)),
                packetDescriptions: nil, sampleBufferOut: &sb)
            audioWritten += n
            return sb!
        }
        func pixelBuffer(_ rgb: (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<48 { for x in 0..<64 {
                let p = base + y * stride + x * 4
                if marker, x < 12, y < 12 { p[0] = 255; p[1] = 255; p[2] = 255; p[3] = 255; continue }
                p[0] = rgb.2; p[1] = rgb.1; p[2] = rgb.0; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return buf
        }
        // One frame per scene tick; each scene's colour, flattened to a per-frame list.
        var colours: [(UInt8, UInt8, UInt8)] = []
        for scene in scenes { colours += Array(repeating: scene.rgb, count: Int((scene.seconds * Double(fps)).rounded())) }
        // Each input is fed from its own queue, the way AVAssetWriter expects, so interleaving cannot stall.
        let group = DispatchGroup()
        var frame = 0
        group.enter()
        vInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video-fixture-v")) {
            while vInput.isReadyForMoreMediaData {
                if frame >= colours.count { vInput.markAsFinished(); group.leave(); return }
                precondition(adaptor.append(pixelBuffer(colours[frame]), withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
                frame += 1
            }
        }
        if let aInput {
            group.enter()
            aInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video-fixture-a")) {
                while aInput.isReadyForMoreMediaData {
                    if audioWritten >= totalAudio { aInput.markAsFinished(); group.leave(); return }
                    precondition(aInput.append(audioChunk()))
                }
            }
        }
        group.wait()
        writer.finishWriting {}
        while writer.status == .writing { Thread.sleep(forTimeInterval: 0.005) }
        precondition(writer.status == .completed, "mp4 fixture failed: \(String(describing: writer.error))")
        return url
    }
}

extension VideoFixtures {
    /// An audio-only file (AAC in an MPEG-4 container) under a `.mp4` name: a movie name with no picture in it.
    static func audioOnlyMP4(seconds: Double = 1.5, name: String = "sound.mp4") -> URL {
        let dir = TestSupport.tempDir("video")
        let m4a = dir.appendingPathComponent("sound.m4a")
        let rate = 44100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
            try file.write(from: buffer)
        } catch { preconditionFailure("m4a fixture failed: \(error)") }       // the file is closed when `file` goes away
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.copyItem(at: m4a, to: url)
        return url
    }
}

/// Stands in for the real frame cutter: writes a small label file (the frame time by default) instead of decoding a
/// movie, records every call and the most frame files that were on disk at once.
final class FakeFrameCutter: FrameCutting {
    private(set) var calls: [Double] = []
    private(set) var maxSides: Set<Int> = []
    private(set) var peakOutstanding = 0
    var written: (Double) -> Bool = { _ in true }
    var failure: (Double) -> Error? = { _ in nil }
    var label: (Double) -> String = { "\($0)" }
    var onCut: ((Double) -> Void)?

    func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool {
        calls.append(time)
        defer { onCut?(time) }
        maxSides.insert(maxSide)
        if let error = failure(time) { throw error }
        guard written(time) else { return false }
        try Data(label(time).utf8).write(to: destination)       // fails if the indexer did not prepare the run folder
        let folder = destination.deletingLastPathComponent()
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jpg") }
        peakOutstanding = max(peakOutstanding, onDisk.count)
        return true
    }
}

/// A one-hot vector of the fake embedder's dimension.
func oneHot(_ i: Int) -> [Float] {
    var v = [Float](repeating: 0, count: FakeEmbedder.dim)
    v[((i % FakeEmbedder.dim) + FakeEmbedder.dim) % FakeEmbedder.dim] = 1
    return v
}
