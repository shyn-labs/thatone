import Foundation
import ThatOneCore

public struct ResultRow: Identifiable, Equatable {
    public enum Why: Equatable {
        case snippet(String)       // the words that matched
        case visual                // matched by what the picture shows
        case none                  // browsing, nothing matched
    }

    public let id: String          // the primary path: stable across searches
    public let path: String
    public let otherPaths: [String]
    public let kind: String
    public let name: String
    public let folder: String
    public let chips: [String]
    public let why: Why
    public let score: Double
    public let modified: Date?
    public let page: Int?          // the first page a match is on (PDFs): where the preview opens
    public let startTime: Double?  // where the first match starts (audio): where the player begins
    public let line: Int?          // the first line of the best code match: where the editor opens
    public let lineEnd: Int?       // its last line: where the preview stops
    public let excerpt: String     // the matched text of the best anchor, for documents' preview

    public init(hit: ServiceHit, home: String = NSHomeDirectory()) {
        let primary = hit.paths.first ?? ""
        id = primary
        path = primary
        otherPaths = Array(hit.paths.dropFirst())
        kind = hit.kind
        name = (primary as NSString).lastPathComponent
        let parent = (primary as NSString).deletingLastPathComponent
        folder = PhotosPath.isPhotos(primary) ? "Apple Photos"
            : parent == home ? "~" : (parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent)
        var seen = Set<String>()
        chips = hit.anchors.compactMap { AnchorChip.text(from: $0.anchor) }.filter { seen.insert($0).inserted }
        page = hit.anchors.compactMap { AnchorChip.page(from: $0.anchor) }.first
        startTime = hit.anchors.compactMap { AnchorChip.startTime(from: $0.anchor) }.first
        let range = hit.anchors.compactMap { AnchorChip.lineRange(from: $0.anchor) }.first
        line = range?.first
        lineEnd = range?.last
        excerpt = hit.anchors.first(where: { !$0.text.isEmpty })?.text ?? ""
        if let match = hit.anchors.first(where: { $0.viaKeyword && !$0.text.isEmpty }) { why = .snippet(match.text) }
        else if hit.anchors.contains(where: { $0.viaVector }) { why = .visual }
        else { why = .none }
        score = hit.score
        modified = hit.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(hit.modified)) : nil
    }
}

/// A short label for where inside a file a match is: a page, a section heading, a part number, a time or a line range.
public enum AnchorChip {
    public static func page(from json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["page"] as? NSNumber)?.intValue
    }

    public static func startTime(from json: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["t0"] as? NSNumber)?.doubleValue
    }

    public static func lineRange(from json: String) -> (first: Int, last: Int)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["line0"] as? NSNumber)?.intValue, let last = (object["line1"] as? NSNumber)?.intValue else { return nil }
        return (first, last)
    }

    public static func text(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let page = (object["page"] as? NSNumber)?.intValue { return "p. \(page)" }
        if let heading = object["heading"] as? String, !heading.isEmpty { return "§ " + (heading.count > 28 ? String(heading.prefix(27)) + "…" : heading) }
        if let part = (object["part"] as? NSNumber)?.intValue { return "part \(part)" }
        if let start = (object["t0"] as? NSNumber)?.doubleValue {
            let seconds = Int(start)
            if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) }   // h:mm:ss
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        if let first = (object["line0"] as? NSNumber)?.intValue, let last = (object["line1"] as? NSNumber)?.intValue {
            return "L\(first)–\(last)"
        }
        return nil
    }
}
