import Foundation

public struct Chunk: Equatable {
    public let text: String
    public let heading: String?       // the heading in force where the chunk starts
    public let index: Int
}

/// Splits text into pieces of about `target` characters on paragraph, sentence and word boundaries. Lengths are in
/// `Character`s, so a Kannada or Hindi grapheme cluster is never cut in half.
public enum TextChunker {
    public static func chunks(_ text: String, target: Int = 1200, maxLength: Int = 1800) -> [Chunk] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = splitParagraphs(normalized)
        var chunks: [Chunk] = []
        var buffer = ""
        var bufferHeading: String?
        var heading: String?

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(Chunk(text: trimmed, heading: bufferHeading, index: chunks.count)) }
            buffer = ""
            bufferHeading = nil
        }

        for (i, paragraph) in paragraphs.enumerated() {
            if isHeading(paragraph, next: i + 1 < paragraphs.count ? paragraphs[i + 1] : nil) {
                flush()
                heading = paragraph
                buffer = paragraph + "\n\n"                      // the heading words are searchable with their section
                bufferHeading = heading
                continue
            }
            for piece in split(paragraph, target: target, maxLength: maxLength) {
                if !buffer.isEmpty, buffer.count + piece.count > target { flush(); bufferHeading = heading }
                if bufferHeading == nil { bufferHeading = heading }
                buffer += (buffer.isEmpty || buffer.hasSuffix("\n\n") ? "" : "\n\n") + piece
            }
        }
        flush()
        return chunks
    }

    static func splitParagraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(String(line).trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// A short single line without sentence punctuation, followed by a clearly longer paragraph.
    static func isHeading(_ paragraph: String, next: String?) -> Bool {
        guard let next, !paragraph.contains("\n"), paragraph.count <= 80, next.count > paragraph.count * 2,
              let last = paragraph.last else { return false }
        return !".,;:!?।。".contains(last)
    }

    /// Pieces of at most `maxLength` characters, packed toward `target` on sentence boundaries; an oversized sentence
    /// is cut at the last whitespace in the window, or hard at `maxLength`.
    static func split(_ paragraph: String, target: Int, maxLength: Int) -> [String] {
        if paragraph.count <= maxLength { return [paragraph] }
        var pieces: [String] = []
        var current = ""
        func push(_ text: String) {
            if !current.isEmpty, current.count + text.count + 1 > target { pieces.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + text
        }
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            if sentence.count <= maxLength { push(sentence); return }
            var rest = Substring(sentence)
            while rest.count > maxLength {
                let window = rest.prefix(maxLength)
                let cut = window.lastIndex(where: { $0.isWhitespace }).map { window.distance(from: window.startIndex, to: $0) } ?? maxLength
                let take = max(cut, 1)
                push(String(rest.prefix(take)).trimmingCharacters(in: .whitespaces))
                rest = rest.dropFirst(take)
            }
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { push(rest.trimmingCharacters(in: .whitespaces)) }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// The anchor JSON stored with a segment: `{"page":4}`, `{"page":4,"part":2}`, `{"heading":"Notice period"}`, `{"part":3}`.
    public static func anchorJSON(page: Int?, part: Int?, heading: String?) -> String {
        var object: [String: Any] = [:]
        if let page { object["page"] = page }
        if let part { object["part"] = part }
        if let heading, !heading.isEmpty { object["heading"] = String(heading.prefix(120)) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
