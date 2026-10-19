import Foundation

/// Source code: decoded as UTF-8, skipped when too large, minified, generated or not text, cut into declaration chunks.
/// Each chunk is embedded with a header line (path, symbol, line range) so the path and the name help the match.
public final class CodeReader: FileReader {
    private let roots: () -> [String]

    public init(roots: @escaping () -> [String] = { [] }) { self.roots = roots }

    public func read(_ url: URL) throws -> ReadResult {
        let path = url.path
        var info = stat()
        guard stat(path, &info) == 0 else { throw ReadFailure.empty("not a text file") }
        if Int64(info.st_size) > CodeRules.maxBytes { throw ReadFailure.tooLarge("larger than 1 MB") }
        guard let data = FileManager.default.contents(atPath: path) else { throw ReadFailure.empty("not a text file") }
        // One pass: the skip check hands back the lines it decoded.
        let lines: [String]
        switch CodeRules.inspect(name: url.lastPathComponent, data: data) {
        case .skip("too large"): throw ReadFailure.tooLarge("larger than 1 MB")      // it grew after the stat
        case .skip(let reason): throw ReadFailure.empty(reason)
        case .lines(let decoded): lines = decoded
        }
        let chunks = CodeChunker.chunks(lines, language: .forExtension(url.pathExtension))
        guard !chunks.isEmpty else { throw ReadFailure.empty("no code") }
        let shown = relativePath(path)
        let segments = chunks.map { chunk -> ReadSegment in
            let code = lines[(chunk.line0 - 1)...(chunk.line1 - 1)].joined(separator: "\n")
            let header = "\(shown) · \(chunk.symbol ?? "lines \(chunk.line0)–\(chunk.line1)") · L\(chunk.line0)–\(chunk.line1)"
            return ReadSegment(modality: "text", anchor: CodeChunker.anchorJSON(line0: chunk.line0, line1: chunk.line1, symbol: chunk.symbol),
                               text: header + "\n" + code)
        }
        // The whole file goes past the secret gate as well, so a key on a line no chunk kept still skips the file.
        return ReadResult(segments: segments, gateText: "\n" + lines.joined(separator: "\n"))
    }

    /// The path below the watched folder that holds the file; the file name when none does.
    func relativePath(_ path: String) -> String {
        for root in roots().map(RealPath.of) {
            let base = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        }
        return (path as NSString).lastPathComponent
    }
}
