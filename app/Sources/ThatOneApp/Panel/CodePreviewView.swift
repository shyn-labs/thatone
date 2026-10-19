import SwiftUI
import ThatOneCore

struct CodeLine: Identifiable, Equatable {
    let number: Int
    let text: String
    var id: Int { number }
}

/// The lines of a code result, numbered as the engine numbers them (same decoding and line splitting, so CRLF files match).
enum CodeExcerpt {
    static let maxLines = 80

    static func lines(path: String, from line0: Int, to line1: Int) -> [CodeLine]? {
        guard line0 >= 1, line1 >= line0,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.int64Value <= CodeRules.maxBytes,
              let data = FileManager.default.contents(atPath: path), let text = CodeRules.decode(data) else { return nil }
        let all = CodeRules.lines(text)
        guard line0 <= all.count else { return nil }
        let last = min(line1, all.count, line0 + maxLines - 1)
        return (line0...last).map { CodeLine(number: $0, text: all[$0 - 1]) }
    }

    /// Without the file: the stored excerpt minus its header line.
    static func fallback(_ excerpt: String) -> String {
        guard let newline = excerpt.firstIndex(of: "\n") else { return excerpt }
        return String(excerpt[excerpt.index(after: newline)...])
    }
}

struct CodePreviewView: View {
    let row: ResultRow
    @State private var lines: [CodeLine]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = row.line {
                Text("Lines \(line)–\(row.lineEnd ?? line)").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 1) {
                    if let lines {
                        ForEach(lines) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(entry.number)").foregroundStyle(.secondary).frame(minWidth: 32, alignment: .trailing)
                                Text(entry.text).textSelection(.enabled)
                            }
                        }
                    } else {
                        Text(CodeExcerpt.fallback(row.excerpt)).textSelection(.enabled)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .task(id: row.id) {
            lines = nil                                       // never show the previous row's lines while this one loads
            let path = row.path, from = row.line ?? 1, to = row.lineEnd ?? (row.line ?? 1)
            lines = await Task.detached(priority: .userInitiated) { CodeExcerpt.lines(path: path, from: from, to: to) }.value
        }
    }
}
