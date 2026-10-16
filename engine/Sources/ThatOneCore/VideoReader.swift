import AVFoundation
import Foundation

public struct VideoInfo: Equatable {
    public var duration: Double
    public var hasVideoTrack: Bool
    public init(duration: Double, hasVideoTrack: Bool) { self.duration = duration; self.hasVideoTrack = hasVideoTrack }
}

/// What the reader needs to know about a video file; faked in tests so no real movie is needed.
public struct VideoProbe {
    public var info: (URL) throws -> VideoInfo
    public init(info: @escaping (URL) throws -> VideoInfo) { self.info = info }

    /// AVFoundation. Loads are bridged synchronously (the reader runs on the indexer's thread) and bounded by 20 s.
    public static let system = VideoProbe(info: { url in
        final class Box: @unchecked Sendable { var value: Result<VideoInfo, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isReadable) else { throw ReadFailure.unreadable("cannot read this video") }
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                box.value = .success(VideoInfo(duration: duration.isFinite ? duration : 0, hasVideoTrack: !tracks.isEmpty))
            } catch { box.value = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success, let result = box.value else {
            task.cancel()
            throw ReadFailure.unreadable("cannot read this video")
        }
        return try result.get()
    })
}

/// Video: one described frame per scheduled time (the indexer cuts the pixels after the secret gate), then the soundtrack
/// through the audio reader. A transcription failure is rethrown: frames are never stored without the transcript.
public final class VideoReader: FileReader {
    private let audio: FileReader
    private let probe: VideoProbe

    public init(audio: FileReader, probe: VideoProbe = .system) {
        self.audio = audio
        self.probe = probe
    }

    public func read(_ url: URL) throws -> ReadResult {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= ReadLimits.maxVideoBytes else { throw ReadFailure.tooLarge(url.lastPathComponent) }
        guard size > 0 else { throw ReadFailure.empty("no video") }           // a placeholder (a download or export still starting)
        let info: VideoInfo
        do { info = try probe.info(url) } catch { throw ReadFailure.unreadable("cannot read this video") }
        guard info.hasVideoTrack, info.duration > 0.05 else { throw ReadFailure.empty("no video") }

        let (step, times) = FrameSchedule.plan(duration: info.duration)
        var notes: [String] = []
        let stepNote = FrameSchedule.note(step: step)
        if !stepNote.isEmpty { notes.append(stepNote) }
        var segments = times.map { time in
            ReadSegment(modality: "frame",
                        anchor: TranscriptChunker.anchorJSON(start: max(time - step / 2, 0), end: min(time + step / 2, info.duration)),
                        text: "", frameSource: url, frameTime: time)
        }
        var gateText = ""
        do {
            let sound = try audio.read(url)
            segments += sound.segments
            gateText = sound.gateText
            if !sound.note.isEmpty { notes.append(sound.note) }
        } catch ReadFailure.unreadable { notes.append("no soundtrack")
        } catch ReadFailure.empty { notes.append("silent soundtrack") }
        return ReadResult(segments: segments, note: notes.joined(separator: "; "), gateText: gateText)
    }
}
