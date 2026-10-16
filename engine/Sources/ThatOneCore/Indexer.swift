import CoreGraphics
import CryptoKit
import Foundation

public enum IndexOutcome: Hashable {
    case indexed
    case linked              // identical content was already indexed under another path
    case unchanged           // same size and mtime as last time
    case removed             // the file is gone
    case skipped(String)     // intentionally not indexed (secret, unsupported, excluded)
    case failed(String)
    case deferred(String)    // the embedder is unavailable: nothing recorded, any earlier entry stays, try again later
}

public enum IndexerError: Error {
    case unreadable(String)
    case ocrFailed(String)
}

/// Turns image files into indexed content: decode, OCR, secret gate, batch embedding, one transaction per file.
public final class Indexer {
    public static let minTextLength = 3
    /// OCR errors are tolerated only for images too small to hold legible text (Vision refuses sides of 2 px or less).
    /// For anything bigger an OCR error means the secret gate could not run, so the file is not embedded.
    static let minOCRSide = 16

    private let store: Store
    private let embedder: Embedder
    private let workDir: URL
    private let exclusions: Exclusions
    private let roots: () -> [String]
    private let ocr: (CGImage) throws -> String
    private let assets: AssetProvider?
    private let enabledKinds: () -> Set<String>
    private let unavailableKinds: () -> Set<String>
    private var keptReads: [String: ReadResult] = [:]      // a transcript kept while its file waits for a pause to end
    private let readers: [String: FileReader]
    private let shouldContinue: () -> Bool
    private let frameCutter: FrameCutting
    /// Temporary JPEGs for the sidecar live here, in a folder private to this run.
    let runDirectory: URL

    public init(store: Store, embedder: Embedder, workDir: URL, exclusions: Exclusions = Exclusions(),
                roots: @escaping () -> [String] = { [] },
                ocr: @escaping (CGImage) throws -> String = { try OCR.text(in: $0) },
                assets: AssetProvider? = nil,
                enabledKinds: @escaping () -> Set<String> = { Kinds.defaultEnabled },
                unavailableKinds: @escaping () -> Set<String> = { [] },
                readers: [String: FileReader]? = nil,
                transcriber: Transcriber? = nil,
                frameCutter: FrameCutting = NoFrameCutter(),
                shouldContinue: @escaping () -> Bool = { true }) {
        self.shouldContinue = shouldContinue
        self.assets = assets
        self.enabledKinds = enabledKinds
        self.unavailableKinds = unavailableKinds
        self.frameCutter = frameCutter
        self.readers = readers ?? Self.makeReaders(ocr: ocr, transcriber: transcriber, shouldContinue: shouldContinue)
        self.store = store
        self.embedder = embedder
        self.workDir = workDir
        self.exclusions = exclusions
        self.roots = roots
        self.ocr = ocr
        self.runDirectory = workDir.appendingPathComponent("run-\(getpid())-\(UUID().uuidString)")
    }

    /// The readers for files that are read whole. Audio and video need the speech model, so they exist only with a transcriber.
    static func makeReaders(ocr: @escaping (CGImage) throws -> String, transcriber: Transcriber?,
                            shouldContinue: @escaping () -> Bool,
                            audioProbe: AudioProbe = .system, videoProbe: VideoProbe = .system) -> [String: FileReader] {
        var made: [String: FileReader] = ["pdf": PDFReader(ocr: ocr), "document": DocumentReader(), "text": DocumentReader()]
        if let transcriber {
            made["audio"] = AudioReader(transcriber: transcriber, probe: audioProbe, shouldContinue: shouldContinue)
            // A soundtrack is as big as its video: the audio part takes the video size cap, not the audio one.
            made["video"] = VideoReader(audio: AudioReader(transcriber: transcriber, probe: audioProbe, shouldContinue: shouldContinue,
                                                           maxBytes: ReadLimits.maxVideoBytes),
                                        probe: videoProbe)
        }
        return made
    }

    deinit { try? FileManager.default.removeItem(at: runDirectory) }

    /// Deletes work folders left by runs that no longer exist (Ctrl-C, crash, power loss) and loose files from before
    /// per-run folders. A run folder belongs to a live process if its pid answers `kill(pid, 0)`.
    public static func sweepStaleRuns(in workDir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("run-") {
                let parts = name.split(separator: "-", maxSplits: 2)
                if parts.count >= 2, let pid = Int32(parts[1]), pid > 0, kill(pid, 0) == 0 || errno == EPERM { continue }
            }
            try? fm.removeItem(at: entry)
        }
    }

    private struct Pending {
        let path: String, hash: String, size: Int64, mtime: Int64
        let jpeg: URL, text: String, note: String
    }

    private enum Triage {
        case done(IndexOutcome)
        case work(size: Int64, mtime: Int64, hash: String, decoded: DecodedImage?)
        case file(kind: String, size: Int64, mtime: Int64, hash: String)      // a PDF or document: read, embedded and stored at once
    }

    public func index(paths: [String]) -> [String: IndexOutcome] {
        var outcomes: [String: IndexOutcome] = [:]
        var pending: [Pending] = []
        var seenHashes = Set<String>()
        var deferred: [String] = []
        let fm = FileManager.default
        // Existing files first: a renamed file then links to its old content by hash before the old path is dropped.
        func exists(_ path: String) -> Bool { PhotosPath.isPhotos(path) || fm.fileExists(atPath: path) }
        let ordered = paths.filter(exists) + paths.filter { !exists($0) }
        for path in ordered {
            do {
                switch try triage(path) {
                case .done(let outcome):
                    outcomes[path] = outcome
                case .file(let kind, let size, let mtime, let hash):
                    outcomes[path] = indexFile(path, kind: kind, size: size, mtime: mtime, hash: hash)
                case .work(let size, let mtime, let hash, let decoded):
                    if !seenHashes.insert(hash).inserted { deferred.append(path); continue }   // identical bytes in this batch
                    if let item = prepare(path, size: size, mtime: mtime, hash: hash, decoded: decoded, outcomes: &outcomes) { pending.append(item) }
                }
            } catch {
                outcomes[path] = recordFailure(path, size: 0, mtime: 0, message: describe(error))
            }
        }
        finish(pending, into: &outcomes)
        if !deferred.isEmpty { outcomes.merge(index(paths: deferred)) { _, new in new } }
        return outcomes
    }

    private func triage(_ path: String) throws -> Triage {
        if PhotosPath.isPhotos(path) { return try triageAsset(path) }
        let fm = FileManager.default
        var info = stat()
        if stat(path, &info) != 0 {
            // Gone for good only if the kernel says so. "Permission denied" (a locked folder, a revoked privacy grant)
            // must not make us forget what we already know about the file.
            if errno == ENOENT || errno == ENOTDIR {
                try store.removeFile(path: path)
                return .done(.removed)
            }
            return .done(.skipped("not accessible"))
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            try store.removeFile(path: path)
            return .done(.removed)
        }
        let root = roots().map(RealPath.of).first { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        let detected = Kinds.detect(path)
        if let detected, unavailableKinds().contains(detected) { return .done(.unchanged) }      // not ours to judge here; the next scan in the owner re-queues it
        guard let kind = detected, enabledKinds().contains(kind), !exclusions.isExcluded(path: path, root: root) else {
            try store.removeFile(path: path)    // newly excluded, switched off or unsupported: forget anything indexed earlier
            return .done(.skipped(detected == nil ? "unsupported file type" : (enabledKinds().contains(detected!) ? "excluded" : "\(detected!) files are switched off")))
        }
        let attributes = try fm.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        if let record = try store.fileRecord(path: path), record.size == size, record.mtime == mtime,
           record.status == "indexed" || record.status == "skipped" {
            return .done(.unchanged)
        }
        let hash = try Self.sha256Hex(of: path)
        if let content = try store.contentByHash(hash) {
            try store.upsertFile(path: path, contentId: content.id, kind: kind, size: size, mtime: mtime,
                                 status: content.status, note: content.note)
            return .done(content.status == "indexed" ? .linked : .skipped(content.note))
        }
        return kind == "image" ? .work(size: size, mtime: mtime, hash: hash, decoded: nil) : .file(kind: kind, size: size, mtime: mtime, hash: hash)
    }

    /// A Photos asset: never `stat`ed, never resolved as a file path.
    private func triageAsset(_ path: String) throws -> Triage {
        guard let parsed = PhotosPath.parse(path) else { return .done(.skipped("not a valid Photos path")) }
        guard let assets else { return .done(.skipped("Apple Photos is not available")) }
        // Without access PhotoKit reports every asset as gone: that is not evidence that a photo was deleted.
        guard [.authorized, .limited].contains(assets.authorization()) else { return .done(.skipped("not accessible")) }
        if exclusions.isExcluded(path: path) {
            try store.removeFile(path: path)
            return .done(.skipped("excluded"))
        }
        guard let info = assets.info(id: parsed.id) else {
            try store.removeFile(path: path)
            return .done(.removed)
        }
        if info.isVideo {
            try store.upsertFile(path: path, contentId: nil, kind: "video", size: info.pixels, mtime: info.mtime,
                                 status: "skipped", note: AssetNotes.video)
            return .done(.skipped(AssetNotes.video))
        }
        if let record = try store.fileRecord(path: path), record.size == info.pixels, record.mtime == info.mtime,
           record.status == "indexed" || (record.status == "skipped" && record.note != AssetNotes.inCloud) {
            return .done(.unchanged)
        }
        switch assets.loadImage(id: parsed.id, maxSide: ImagePrep.ocrMaxSide) {
        case .inCloud:
            try store.upsertFile(path: path, contentId: nil, kind: "image", size: info.pixels, mtime: info.mtime,
                                 status: "skipped", note: AssetNotes.inCloud)
            return .done(.skipped(AssetNotes.inCloud))
        case .failed(let message):
            throw IndexerError.unreadable(message)
        case .image(let image):
            let decoded = try ImagePrep.decode(cgImage: image)
            guard let jpeg = ImagePrep.jpegData(decoded.smallImage) else { throw ImagePrepError.unreadable("photos") }
            let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
            if let content = try store.contentByHash(hash) {
                try store.upsertFile(path: path, contentId: content.id, kind: "image", size: info.pixels, mtime: info.mtime,
                                     status: content.status, note: content.note)
                return .done(content.status == "indexed" ? .linked : .skipped(content.note))
            }
            return .work(size: info.pixels, mtime: info.mtime, hash: hash, decoded: decoded)
        }
    }

    private func prepare(_ path: String, size: Int64, mtime: Int64, hash: String, decoded preDecoded: DecodedImage?,
                         outcomes: inout [String: IndexOutcome]) -> Pending? {
        do {
            let decoded = try preDecoded ?? ImagePrep.decode(URL(fileURLWithPath: path))
            var text = ""
            var note = ""
            do { text = try ocr(decoded.ocrImage) }
            catch {
                guard min(decoded.ocrImage.width, decoded.ocrImage.height) < Self.minOCRSide else {
                    throw IndexerError.ocrFailed(error.localizedDescription)
                }
                note = String("ocr failed: \(error.localizedDescription)".prefix(200))   // too small to hold text anyway
            }
            if SecretGate.containsSecret(text) {
                let id = try store.addContent(hash: hash, kind: "image", status: "skipped", note: "secret", segments: [])
                try store.upsertFile(path: path, contentId: id, kind: "image", size: size, mtime: mtime,
                                     status: "skipped", note: "secret")
                outcomes[path] = .skipped("secret")
                return nil
            }
            // Only now does a copy of the image reach disk, and only in this run's private folder.
            let jpeg = runDirectory.appendingPathComponent("\(hash).jpg")
            try ImagePrep.writeJPEG(decoded.smallImage, to: jpeg)
            return Pending(path: path, hash: hash, size: size, mtime: mtime, jpeg: jpeg, text: text, note: note)
        } catch {
            outcomes[path] = recordFailure(path, size: size, mtime: mtime, message: describe(error))
            return nil
        }
    }

    private func finish(_ pending: [Pending], into outcomes: inout [String: IndexOutcome]) {
        guard !pending.isEmpty else { return }
        defer { for item in pending { try? FileManager.default.removeItem(at: item.jpeg) } }
        let imageResults = embedIsolating(embedder, .image, inputs: pending.map { $0.jpeg.path })
        let textIndices = pending.indices.filter { pending[$0].text.count >= Self.minTextLength }
        let textResults = embedIsolating(embedder, .text, inputs: textIndices.map { pending[$0].text })
        var textByIndex: [Int: Result<[Float], Error>] = [:]
        for (slot, index) in textIndices.enumerated() { textByIndex[index] = textResults[slot] }

        for (i, item) in pending.enumerated() {
            // Embedding takes a while: the kind may have been switched off meanwhile (Photos have their own switch).
            if !PhotosPath.isPhotos(item.path), !enabledKinds().contains("image") { outcomes[item.path] = .removed; continue }
            // ... or the asset deleted, or Photos switched off.
            if let parsed = PhotosPath.parse(item.path), assets?.info(id: parsed.id) == nil {
                outcomes[item.path] = .removed
                continue
            }
            do {
                var segments = [SegmentInput(modality: "image", text: item.text, vector: try imageResults[i].get())]
                if let result = textByIndex[i] {
                    segments.append(SegmentInput(modality: "text", text: item.text, vector: try result.get()))
                }
                outcomes[item.path] = try store.transaction {
                    if let existing = try store.contentByHash(item.hash) {   // stored meanwhile by an identical file
                        try store.upsertFile(path: item.path, contentId: existing.id, kind: "image", size: item.size,
                                             mtime: item.mtime, status: existing.status, note: existing.note)
                        return IndexOutcome.linked
                    }
                    let id = try store.addContent(hash: item.hash, kind: "image", status: "indexed", note: item.note, segments: segments)
                    try store.upsertFile(path: item.path, contentId: id, kind: "image", size: item.size,
                                         mtime: item.mtime, status: "indexed", note: item.note)
                    return IndexOutcome.indexed
                }
            } catch {
                if Self.isUnavailable(error) {
                    outcomes[item.path] = .deferred(describe(error))
                } else {
                    outcomes[item.path] = recordFailure(item.path, size: item.size, mtime: item.mtime, message: describe(error))
                }
            }
        }
    }


    /// A PDF, document or text file: read into segments, secret-gated as a whole, embedded in groups, stored in one go.
    private func indexFile(_ path: String, kind: String, size: Int64, mtime: Int64, hash: String) -> IndexOutcome {
        guard let reader = readers[kind] else { return .skipped("unsupported file type") }
        let result: ReadResult
        do { result = try keptReads[hash] ?? reader.read(URL(fileURLWithPath: path)) }
        catch let failure as ReadFailure {
            switch failure {
            case .locked: return recordSkip(path, kind, size, mtime, "password-protected")
            case .empty(let why): return recordSkip(path, kind, size, mtime, why)
            case .tooLarge: return recordSkip(path, kind, size, mtime, "too large")
            case .unreadable(let why): return recordFailure(path, size: size, mtime: mtime, message: "cannot read: \(String(why.prefix(120)))")
            case .timedOut: return recordFailure(path, size: size, mtime: mtime, message: "reading took too long")
            }
        } catch let failure as TranscribeFailure {
            switch failure {
            case .unavailable(let why): return .deferred("transcription unavailable: \(why)")
            case .interrupted: return .deferred("paused")
            case .failed(let why): return recordFailure(path, size: size, mtime: mtime, message: "transcription failed: \(String(why.prefix(120)))")
            }
        } catch { return recordFailure(path, size: size, mtime: mtime, message: describe(error)) }

        keptReads[hash] = nil                                 // consumed; a pause below puts it back
        do {
            // One secret anywhere (text layer, OCR, document body) skips the whole file, before any image is written.
            // Also the text laid end to end (a key the chunker cut in half) and the part beyond a reader's character limit.
            let continuous = result.segments.map { $0.text }.joined() + result.gateText
            if result.segments.contains(where: { SecretGate.containsSecret($0.text) }) || SecretGate.containsSecret(continuous) {
                let id = try store.addContent(hash: hash, kind: kind, status: "skipped", note: "secret", segments: [])
                try store.upsertFile(path: path, contentId: id, kind: kind, size: size, mtime: mtime, status: "skipped", note: "secret")
                return .skipped("secret")
            }
            var vectors: [Int: [Float]] = [:]
            let texts = result.segments.indices.filter { result.segments[$0].modality == "text" }
            for group in stride(from: 0, to: texts.count, by: 16).map({ Array(texts[$0..<min($0 + 16, texts.count)]) }) {
                let results = embedIsolating(embedder, .text, inputs: group.map { result.segments[$0].text })
                for (slot, index) in group.enumerated() { vectors[index] = try results[slot].get() }
            }
            let images = result.segments.indices.filter { result.segments[$0].modality == "image" && result.segments[$0].image != nil }
            var written: [URL] = []
            defer { for url in written { try? FileManager.default.removeItem(at: url) } }
            for group in stride(from: 0, to: images.count, by: 8).map({ Array(images[$0..<min($0 + 8, images.count)]) }) {
                var urls: [URL] = []
                for index in group {
                    let url = runDirectory.appendingPathComponent("\(hash)-\(index).jpg")
                    try ImagePrep.writeJPEG(result.segments[index].image!, to: url)
                    written.append(url); urls.append(url)
                }
                let results = embedIsolating(embedder, .image, inputs: urls.map { $0.path })
                for (slot, index) in group.enumerated() { vectors[index] = try results[slot].get() }
            }
            // Sound: the windows are cut to small WAV files only now, after the gate, a few at a time.
            let sounds = result.segments.indices.filter { result.segments[$0].modality == "audio" && result.segments[$0].audioSource != nil && result.segments[$0].audioRange != nil }
            for group in stride(from: 0, to: sounds.count, by: 4).map({ Array(sounds[$0..<min($0 + 4, sounds.count)]) }) {
                guard shouldContinue() else { keptReads = [hash: result]; return .deferred("paused") }   // yields between windows; the transcript waits with it
                var urls: [URL] = []
                for index in group {
                    let url = runDirectory.appendingPathComponent("\(hash)-w\(index).wav")
                    written.append(url)
                    do { try AudioWindows.extract(source: result.segments[index].audioSource!, range: result.segments[index].audioRange!, to: url) }
                    catch { throw ReadFailure.unreadable("cannot cut an audio window (\(String(describing: error).prefix(80)))") }
                    urls.append(url)
                }
                let results = embedIsolating(embedder, .audio, inputs: urls.map { $0.path })
                for (slot, index) in group.enumerated() { vectors[index] = try results[slot].get() }
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }
            // Pictures of a video: cut to JPEGs only now, after the gate, 8 at a time and deleted after each group, so a
            // 720-frame video never has more than 8 decoded frames around. Near-duplicates of the last kept frame get no
            // vector and so are not stored. Only the transcript survives a pause; the frames are cut again on the retry.
            let frames = result.segments.indices.filter { result.segments[$0].modality == "frame" && result.segments[$0].frameSource != nil && result.segments[$0].frameTime != nil }
            var lastKept: [Float]?
            var framesRead = 0, framesSkipped = 0
            if !frames.isEmpty { try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true) }
            for group in stride(from: 0, to: frames.count, by: 8).map({ Array(frames[$0..<min($0 + 8, frames.count)]) }) {
                guard shouldContinue() else { keptReads = [hash: result]; return .deferred("paused") }
                guard enabledKinds().contains(kind) else { return .removed }      // switched off mid-video: no more frames are cut
                var cut: [(index: Int, url: URL)] = []
                var urls: [URL] = []
                defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
                for index in group {
                    let url = runDirectory.appendingPathComponent("\(hash)-f\(index).jpg")
                    written.append(url); urls.append(url)
                    let made: Bool
                    do { made = try frameCutter.cut(source: result.segments[index].frameSource!, time: result.segments[index].frameTime!,
                                                    maxSide: ImagePrep.embedMaxSide, to: url) }
                    catch let failure as ReadFailure { throw failure }                  // the file itself: it fails
                    catch { keptReads = [hash: result]; return .deferred("\(Indexer.frameCuttingUnavailable): \(String(describing: error).prefix(120))") }   // the environment: it waits
                    if made { cut.append((index, url)) } else { framesSkipped += 1 }                     // false: a blank or undecodable frame, skipped
                }
                guard !cut.isEmpty else { continue }
                framesRead += cut.count
                let results = embedIsolating(embedder, .image, inputs: cut.map { $0.url.path })
                let groupVectors = try results.map { try $0.get() }
                for slot in FrameDedupe.kept(groupVectors, after: lastKept) {
                    vectors[cut[slot].index] = groupVectors[slot]
                    lastKept = groupVectors[slot]
                }
            }
            guard enabledKinds().contains(kind) else { return .removed }      // switched off while this file was being read and embedded
            var note = result.note
            if kind == "video" {
                if vectors.isEmpty { return recordSkip(path, kind, size, mtime, "no usable frames or sound") }
                let frameNote = !frames.isEmpty && framesRead == 0 ? "no frames could be read"
                    : framesSkipped > 0 ? "\(framesSkipped) frames skipped (blank or unreadable)" : ""
                if !frameNote.isEmpty { note = note.isEmpty ? frameNote : note + "; " + frameNote }
            }
            let segments = result.segments.indices.compactMap { i -> SegmentInput? in
                vectors[i].map { SegmentInput(modality: result.segments[i].modality, anchor: result.segments[i].anchor,
                                              text: result.segments[i].text, vector: $0) }
            }
            return try store.transaction {
                if let existing = try store.contentByHash(hash) {                 // stored meanwhile by an identical file
                    try store.upsertFile(path: path, contentId: existing.id, kind: kind, size: size, mtime: mtime,
                                         status: existing.status, note: existing.note)
                    return IndexOutcome.linked
                }
                let id = try store.addContent(hash: hash, kind: kind, status: "indexed", note: note, segments: segments)
                try store.upsertFile(path: path, contentId: id, kind: kind, size: size, mtime: mtime, status: "indexed", note: note)
                return IndexOutcome.indexed
            }
        } catch {
            if Self.isUnavailable(error) { return .deferred(describe(error)) }
            return recordFailure(path, size: size, mtime: mtime, message: describe(error))
        }
    }

    private func recordSkip(_ path: String, _ kind: String, _ size: Int64, _ mtime: Int64, _ why: String) -> IndexOutcome {
        try? store.upsertFile(path: path, contentId: nil, kind: kind, size: size, mtime: mtime, status: "skipped", note: why)
        return .skipped(why)
    }

    private func recordFailure(_ path: String, size: Int64, mtime: Int64, message: String) -> IndexOutcome {
        // contentId nil: whatever this path held before is dropped, so a file that broke never serves stale results
        try? store.upsertFile(path: path, contentId: nil, kind: Kinds.detect(path) ?? "image", size: size,
                              mtime: mtime, status: "failed", note: message)
        return .failed(message)
    }

    /// Reason prefix of a video waiting on an environment problem while its frames were cut (not the file's fault).
    static let frameCuttingUnavailable = "frame cutting unavailable"

    /// The embedding worker cannot be used at all (not installed, kept crashing, never answered): an environment
    /// problem, not something wrong with this file, so the file waits instead of failing.
    static func isUnavailable(_ error: Error) -> Bool {
        if error is SidecarEmbedder.Failure || error is EngineError { return true }
        if error is ReadFailure { return false }
        if error is SidecarError || error is StoreError || error is ImagePrepError || error is IndexerError { return false }
        return true          // launching the worker threw (missing uv or script): the environment, not the file
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case ReadFailure.unreadable(let why): return "cannot read: \(String(why.prefix(120)))"
        case ReadFailure.timedOut: return "reading took too long"
        case ImagePrepError.unreadable: return "cannot decode image"
        case ImagePrepError.tooLarge: return "image too large"
        case IndexerError.ocrFailed(let why): return "ocr failed: \(String(why.prefix(200)))"
        case SidecarError.remote(let code, let message): return "embedding \(code): \(message)"
        case SidecarError.workerExited(let status): return "embedding worker exited (\(status))"
        case SidecarEmbedder.Failure.unavailable(let why): return "embedding unavailable: \(why)"
        default: return String(describing: error)
        }
    }

    public static func sha256Hex(of path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw IndexerError.unreadable(path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
