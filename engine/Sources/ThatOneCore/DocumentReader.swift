import Foundation

/// Word-style documents (docx, doc, rtf, odt, html) through macOS's `textutil`, which runs as a separate process with a
/// time and size limit; plain text (txt, md) is read directly. The text is chunked on paragraph and heading boundaries.
public final class DocumentReader: FileReader {
    private let textutil: String
    private let timeout: TimeInterval
    private let maxOutputBytes: Int
    private let sandboxed: Bool

    /// Converting a document must never reach the network: HTML and Office files can point at remote images, style
    /// sheets and templates, and fetching them would leak that this file was read. The converter therefore runs under
    /// `sandbox-exec` with network access and file writes denied. Tests may turn that off to prove it matters.
    static let sandboxProfile = "(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (literal \"/dev/null\"))"

    public init(textutil: String = "/usr/bin/textutil", timeout: TimeInterval = 30, maxOutputBytes: Int = 50_000_000,
                sandboxed: Bool = true) {
        self.sandboxed = sandboxed
        self.textutil = textutil
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    public func read(_ url: URL) throws -> ReadResult {
        let ext = url.pathExtension.lowercased()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= ReadLimits.maxFileBytes else { throw ReadFailure.tooLarge(url.lastPathComponent) }
        let data: Data
        if ext == "txt" || ext == "md" {
            guard size <= Int64(maxOutputBytes) else { throw ReadFailure.tooLarge(url.lastPathComponent) }
            guard let contents = FileManager.default.contents(atPath: url.path) else { throw ReadFailure.unreadable("cannot read the file") }
            data = contents
        } else {
            try Self.checkSignature(url, ext: ext)
            data = Self.paragraphPerLine(try convert(url))
        }
        var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{0}", with: "")
        var notes: [String] = []
        var gateText = ""
        if text.count > ReadLimits.maxChars {
            gateText = String(text.dropFirst(ReadLimits.maxChars).prefix(20_000))
            text = String(text.prefix(ReadLimits.maxChars))
            notes.append("first \(ReadLimits.maxChars) characters")
        }
        let chunks = TextChunker.chunks(text)
        guard !chunks.isEmpty else { throw ReadFailure.empty("no text found") }
        let segments = chunks.map {
            ReadSegment(modality: "text", anchor: TextChunker.anchorJSON(page: nil, part: $0.index + 1, heading: $0.heading), text: $0.text)
        }
        return ReadResult(segments: segments, note: notes.joined(separator: "; "), gateText: gateText)
    }

    /// textutil quietly treats a file it cannot parse as plain text (a corrupt .docx comes out as garbage), so the
    /// container format is checked first.
    static func checkSignature(_ url: URL, ext: String) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ReadFailure.unreadable("cannot open the file") }
        defer { try? handle.close() }
        var bytes = [UInt8]((try? handle.read(upToCount: 16)) ?? Data())
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }                  // a UTF-8 byte order mark
        let valid: Bool
        switch ext {
        case "docx", "odt": valid = bytes.starts(with: [0x50, 0x4B])                       // a zip container
        case "doc": valid = bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) || bytes.starts(with: [0x7B, 0x5C, 0x72, 0x74])
            || bytes.first == 0x3C                                                           // OLE, RTF in disguise, or Word's HTML/XML "web page" export
        case "rtf": valid = bytes.starts(with: [0x7B, 0x5C, 0x72, 0x74])                  // {\rt
        default: valid = true                                                              // html and others are text
        }
        guard valid else { throw ReadFailure.unreadable("not a valid .\(ext) file") }
    }

    /// textutil writes one paragraph per line; the chunker wants blank lines between paragraphs.
    static func paragraphPerLine(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Data(lines.joined(separator: "\n\n").utf8)
    }

    /// `textutil -convert txt -stdout`, killed if it runs too long or prints too much.
    private func convert(_ url: URL) throws -> Data {
        let process = Process()
        let arguments = ["-convert", "txt", "-encoding", "UTF-8", "-stdout", url.path]
        if sandboxed {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
                throw ReadFailure.unreadable("cannot convert documents safely on this Mac")   // never run unconfined
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", Self.sandboxProfile, textutil] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: textutil)
            process.arguments = arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw ReadFailure.unreadable("textutil is not available") }

        let state = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            state.lock()
            if process.isRunning { timedOut = true; process.terminate() }      // a process that already finished is not a timeout
            state.unlock()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        var output = Data()
        var tooLarge = false
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > maxOutputBytes { tooLarge = true; process.terminate(); break }
        }
        if tooLarge { _ = try? handle.close() }
        process.waitUntilExit()
        watchdog.cancel()
        state.lock(); let expired = timedOut; state.unlock()
        if expired { throw ReadFailure.timedOut }
        if tooLarge { throw ReadFailure.tooLarge(url.lastPathComponent) }
        guard process.terminationStatus == 0 else { throw ReadFailure.unreadable("the document could not be converted") }
        return output
    }
}
