import CoreGraphics
import Foundation

/// One searchable piece of a file: a page, a section, or a rendered scanned page.
public struct ReadSegment {
    public var modality: String       // "text" | "image"
    public var anchor: String         // JSON, e.g. {"page":3} or {"heading":"Notice"}
    public var text: String
    public var image: CGImage?        // only for modality "image": already downscaled for the embedder
    public var audioSource: URL?      // only for modality "audio": the file and the time range (seconds) to cut when it is embedded
    public var audioRange: ClosedRange<Double>?
    public var frameSource: URL?      // only for a video frame: the file and the time (seconds) to cut when it is embedded
    public var frameTime: Double?
    public init(modality: String, anchor: String, text: String, image: CGImage? = nil,
                audioSource: URL? = nil, audioRange: ClosedRange<Double>? = nil,
                frameSource: URL? = nil, frameTime: Double? = nil) {
        self.frameSource = frameSource; self.frameTime = frameTime
        self.modality = modality; self.anchor = anchor; self.text = text; self.image = image
        self.audioSource = audioSource; self.audioRange = audioRange
    }
}

public struct ReadResult {
    public var segments: [ReadSegment]
    public var note: String           // "" or what was cut off, e.g. "first 400 pages"
    public var gateText: String       // text beyond what was kept, still checked for secrets (a key can straddle the cut)
    public init(segments: [ReadSegment], note: String = "", gateText: String = "") {
        self.segments = segments; self.note = note; self.gateText = gateText
    }
}

public enum ReadFailure: Error, Equatable {
    case locked                       // password-protected
    case empty(String)                // nothing readable in it
    case tooLarge(String)
    case unreadable(String)
    case timedOut
}

public protocol FileReader {
    /// Blocking; runs on the indexer's thread. Never loads more than the limits below.
    func read(_ url: URL) throws -> ReadResult
}

public enum ReadLimits {
    public static var maxFileBytes: Int64 = 200_000_000
    public static var maxPages = 400
    public static var maxScannedPages = 60
    public static var maxChars = 3_000_000
    /// A page with fewer characters than this is treated as scanned (an image of text).
    public static var scannedPageThreshold = 25
    public static var maxAudioBytes: Int64 = 2_000_000_000
    public static var maxTranscribeSeconds = 3 * 3600
    public static var maxEmbedSeconds = 3600
    public static var windowSeconds = 30
    /// Speech separated by more than this many seconds of silence is never merged into one transcript chunk.
    public static var chunkGapSeconds: Double = 8
    /// A second whose RMS level is below this counts as silence.
    public static var silenceRMS: Float = 0.003
    public static var maxVideoBytes: Int64 = 8_000_000_000
    public static var maxFrames = 720
    /// Seconds between sampled frames, at the least.
    public static var minFrameStep = 5.0
    /// A frame this similar (cosine) to the last kept one is dropped.
    public static var frameDuplicateCosine: Float = 0.97
    /// A frame whose brightness spread is below this is blank.
    public static var blankFrameSpread = 3
}
