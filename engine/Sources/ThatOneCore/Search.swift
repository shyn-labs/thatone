import Foundation

public struct SearchFilters: Equatable {
    public var kinds: Set<String>
    public var folder: String?
    public var since: Int64?
    public var until: Int64?
    public init(kinds: Set<String> = [], folder: String? = nil, since: Int64? = nil, until: Int64? = nil) {
        self.kinds = kinds; self.folder = folder; self.since = since; self.until = until
    }
    public var isEmpty: Bool { kinds.isEmpty && folder == nil && since == nil && until == nil }
}

public struct SearchAnchor: Equatable {
    public let segmentId: Int64
    public let modality: String
    public let anchor: String
    public let text: String
    public let viaKeyword: Bool    // the segment was among the FTS5 matches for the query words
    public let viaVector: Bool     // the segment was among the nearest vectors to the query
}

public struct SearchHit: Equatable {
    public let contentId: Int64
    public let kind: String
    public let score: Double
    public let modified: Int64     // newest mtime among its paths, unix seconds
    public let paths: [String]
    public let anchors: [SearchAnchor]
}

public enum Tokens {
    private static let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{M}\\p{N}_]+")

    /// Unicode letters, marks (Indic vowel signs) and digits; `\w` would split Kannada and Hindi words.
    public static func words(_ text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    /// An FTS5 MATCH expression that ORs the distinct quoted words, or nil when there are none.
    public static func ftsExpression(_ text: String, maxTokens: Int = 32) -> String? {
        var seen = Set<String>()
        var out: [String] = []
        for word in words(text) where !seen.contains(word) {
            seen.insert(word)
            out.append("\"\(word)\"")
            if out.count == maxTokens { break }
        }
        return out.isEmpty ? nil : out.joined(separator: " OR ")
    }
}

public struct Searcher {
    public static let rrfK = 60.0
    public static let pool = 100
    public static let widePool = 400
    public static let maxAnchors = 3
    public static let maxLimit = 500
    /// The vector search fetches this many times the pool, then keeps at most `maxPerContent` segments of each file, so
    /// a few long videos (hundreds of distinct frames each) cannot fill the pool and push every other file out.
    public static let vectorOversample = 4
    public static let maxPerContent = 5
    /// While hidden kinds are in the index, a search that names no kind fetches this many times more vectors, so a large
    /// code index cannot push everything else out of it. A search that names kinds fetches `maxVectorK` and keeps only
    /// those kinds. The keyword search needs no widening: it filters by kind inside its own SQL.
    public static let hiddenOversample = 4
    /// sqlite-vec refuses a larger k. A KNN query cannot filter by kind, so past this cap enough nearer hidden-kind
    /// segments can still crowd the vector list; the keyword list has no such ceiling.
    static let maxVectorK = 4096

    /// A caller-supplied limit is never trusted: negative or absurd values would trap or overflow below.
    static func clamp(_ limit: Int) -> Int { max(0, min(limit, maxLimit)) }
    public let store: Store
    public init(store: Store) { self.store = store }

    private struct SegmentRow { let id: Int64; let contentId: Int64; let modality: String; let anchor: String; let text: String }
    private struct FileInfo { var kind: String; var paths: [String]; var modified: Int64 }

    public func search(query: String, queryVector: [Float]?, filters: SearchFilters = SearchFilters(),
                       limit rawLimit: Int = 10) throws -> [SearchHit] {
        let limit = Searcher.clamp(rawLimit)
        let k = filters.isEmpty ? Searcher.pool : Searcher.widePool   // filters run after retrieval
        let hidden = Kinds.hiddenByDefault.subtracting(filters.kinds)   // hidden kinds this search does not name
        let crowded = try filters.kinds.isEmpty && holdsContent(ofKinds: hidden)   // named kinds are filtered on both sides
        let widen = crowded ? Searcher.hiddenOversample : 1
        var lists: [[Int64]] = []
        var viaVector = Set<Int64>()
        var viaKeyword = Set<Int64>()
        if let v = queryVector {
            guard v.count == store.dim else { throw StoreError.badVector(expected: store.dim, got: v.count) }
            // vec0's KNN cannot join to the content's kind, so kinds are dropped after the fetch, capped at maxVectorK: hidden
            // kinds not named, or, when kinds are named, every kind that is not. A named-kind search fetches the most it can.
            let fetch = filters.kinds.isEmpty ? min(k * Searcher.vectorOversample * widen, Searcher.maxVectorK) : Searcher.maxVectorK
            let nearest = try store.query(
                "select rowid from segment_vectors where embedding match ? and k = \(fetch) order by distance",
                [.blob(Store.vectorBlob(v))]) { $0.int(0) }
            let named = filters.kinds
            let ids = try capPerContent(nearest, limit: k, keeping: { named.isEmpty ? !(crowded && hidden.contains($0)) : named.contains($0) })
            viaVector = Set(ids)
            lists.append(ids)
        }
        if let expression = Tokens.ftsExpression(query) {
            let ids: [Int64]
            if !filters.kinds.isEmpty {   // only the named kinds, inside the query, so no number of other matches fills the pool
                let marks = Array(repeating: "?", count: filters.kinds.count).joined(separator: ",")
                ids = try store.query(
                    "select segments_fts.rowid from segments_fts join segments s on s.id = segments_fts.rowid"
                        + " join contents c on c.id = s.content_id"
                        + " where segments_fts match ? and c.kind in (\(marks)) order by segments_fts.rank limit \(k)",
                    [.text(expression)] + filters.kinds.sorted().map { .text($0) }) { $0.int(0) }
            } else if crowded {   // leave the hidden kinds out inside the query, so no number of their matches fills the pool
                let marks = Array(repeating: "?", count: hidden.count).joined(separator: ",")
                ids = try store.query(
                    "select segments_fts.rowid from segments_fts join segments s on s.id = segments_fts.rowid"
                        + " join contents c on c.id = s.content_id"
                        + " where segments_fts match ? and c.kind not in (\(marks)) order by segments_fts.rank limit \(k)",
                    [.text(expression)] + hidden.sorted().map { .text($0) }) { $0.int(0) }
            } else {
                ids = try store.query(
                    "select rowid from segments_fts where segments_fts match ? order by rank limit \(k)",
                    [.text(expression)]) { $0.int(0) }
            }
            viaKeyword = Set(ids)
            lists.append(ids)
        }
        var score: [Int64: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() { score[id, default: 0] += 1.0 / (Searcher.rrfK + Double(rank) + 1.0) }
        }
        guard !score.isEmpty else { return [] }

        var segments: [SegmentRow] = []
        let ids = Array(score.keys)
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            segments += try store.query(
                "select id, content_id, modality, anchor, text from segments where id in (\(marks))",
                chunk.map { .int($0) }) {
                SegmentRow(id: $0.int(0), contentId: $0.int(1), modality: $0.text(2), anchor: $0.text(3), text: $0.text(4))
            }
        }
        var byContent: [Int64: [SegmentRow]] = [:]
        for s in segments { byContent[s.contentId, default: []].append(s) }

        let files = try filesFor(Array(byContent.keys), filters)
        var hits: [SearchHit] = []
        for (contentId, rows) in byContent {
            guard let f = files[contentId] else { continue }
            let ranked = rows.sorted { (score[$0.id] ?? 0, -$0.id) > (score[$1.id] ?? 0, -$1.id) }
            hits.append(SearchHit(
                contentId: contentId, kind: f.kind, score: score[ranked[0].id] ?? 0, modified: f.modified,
                paths: f.paths.sorted(),
                anchors: ranked.prefix(Searcher.maxAnchors).map {
                    SearchAnchor(segmentId: $0.id, modality: $0.modality, anchor: $0.anchor,
                                 text: String($0.text.prefix(160)),
                                 viaKeyword: viaKeyword.contains($0.id), viaVector: viaVector.contains($0.id))
                }))
        }
        hits.sort { ($0.score, -$0.contentId) > ($1.score, -$1.contentId) }
        return Array(hits.prefix(limit))
    }

    /// The content and kind owning each segment id.
    private func owners(of ids: [Int64]) throws -> [Int64: (content: Int64, kind: String)] {
        var out: [Int64: (content: Int64, kind: String)] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for (id, content, kind) in try store.query(
                "select s.id, s.content_id, c.kind from segments s join contents c on c.id = s.content_id where s.id in (\(marks))",
                chunk.map { .int($0) }, { ($0.int(0), $0.int(1), $0.text(2)) }) {
                out[id] = (content, kind)
            }
        }
        return out
    }

    /// `ids` (nearest first) of the kinds `keeping` accepts, with at most `maxPerContent` segments of any one content, cut to `limit`.
    private func capPerContent(_ ids: [Int64], limit: Int, keeping: (String) -> Bool) throws -> [Int64] {
        let owner = try owners(of: ids)
        var taken: [Int64: Int] = [:]
        var kept: [Int64] = []
        for id in ids {
            guard kept.count < limit else { break }
            guard let o = owner[id], keeping(o.kind) else { continue }
            if taken[o.content, default: 0] >= Searcher.maxPerContent { continue }
            taken[o.content, default: 0] += 1
            kept.append(id)
        }
        return kept
    }

    private func holdsContent(ofKinds kinds: Set<String>) throws -> Bool {
        guard !kinds.isEmpty else { return false }
        let marks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        return try store.int("select exists(select 1 from contents where status = 'indexed' and kind in (\(marks)))",
                             kinds.sorted().map { .text($0) }) == 1
    }

    /// The newest indexed files first, one hit per content (browsing without a query).
    public func recent(filters: SearchFilters = SearchFilters(), limit rawLimit: Int = 60) throws -> [SearchHit] {
        let limit = Searcher.clamp(rawLimit)
        let c = Self.clauses(filters)
        let rows = try store.query(
            "select content_id, kind, path, mtime from files where status = 'indexed' and content_id is not null"
                + c.sql + " order by mtime desc, path limit ?",
            c.binds + [.int(Int64(limit) * 4)]) { ($0.int(0), $0.text(1), $0.text(2), $0.int(3)) }
        var order: [Int64] = []
        var info: [Int64: FileInfo] = [:]
        for (contentId, kind, path, mtime) in rows {
            if info[contentId] == nil {
                order.append(contentId)
                info[contentId] = FileInfo(kind: kind, paths: [], modified: mtime)
            }
            info[contentId]?.paths.append(path)
        }
        return order.prefix(limit).compactMap { id in
            info[id].map { SearchHit(contentId: id, kind: $0.kind, score: 0, modified: $0.modified,
                                     paths: $0.paths.sorted(), anchors: []) }
        }
    }

    /// Files that look like this one: nearest neighbours of its (image first) vector, never the content itself. With no kinds
    /// named, a hidden-kind source (code) searches its own kind.
    public func similar(toContentId contentId: Int64, filters: SearchFilters = SearchFilters(),
                        limit rawLimit: Int = 30) throws -> [SearchHit] {
        let limit = Searcher.clamp(rawLimit)
        guard let vector = try vector(ofContent: contentId) else { return [] }
        var filters = filters
        if filters.kinds.isEmpty,   // more like a code file means more code: name the source's hidden kind
           let kind = try store.query("select kind from contents where id = ?", [.int(contentId)], { $0.text(0) }).first,
           Kinds.hiddenByDefault.contains(kind) {
            filters.kinds = [kind]
        }
        let hits = try search(query: "", queryVector: vector, filters: filters, limit: limit + 1)
        return Array(hits.filter { $0.contentId != contentId }.prefix(limit))
    }

    func vector(ofContent contentId: Int64) throws -> [Float]? {
        let segmentIds = try store.query(
            "select id from segments where content_id = ? order by case modality when 'image' then 0 when 'frame' then 0 else 1 end, id",
            [.int(contentId)]) { $0.int(0) }
        for id in segmentIds {
            let blob = try store.query("select embedding from segment_vectors where rowid = ?", [.int(id)]) { $0.blob(0) }.first
            if let blob, blob.count == store.dim * MemoryLayout<Float>.size {
                return blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        return nil
    }

    private static func clauses(_ f: SearchFilters) -> (sql: String, binds: [Bind]) {
        var sql = ""
        var binds: [Bind] = []
        if !f.kinds.isEmpty {
            sql += " and kind in (" + Array(repeating: "?", count: f.kinds.count).joined(separator: ",") + ")"
            binds += f.kinds.sorted().map { .text($0) }
        } else if !Kinds.hiddenByDefault.isEmpty {     // a search that names no kind leaves code out
            sql += " and kind not in (" + Array(repeating: "?", count: Kinds.hiddenByDefault.count).joined(separator: ",") + ")"
            binds += Kinds.hiddenByDefault.sorted().map { .text($0) }
        }
        if let folder = f.folder {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            sql += " and substr(path, 1, ?) = ?"
            binds += [.int(Int64(prefix.unicodeScalars.count)), .text(prefix)]
        }
        if let since = f.since { sql += " and mtime >= ?"; binds.append(.int(since)) }
        if let until = f.until { sql += " and mtime <= ?"; binds.append(.int(until)) }
        return (sql, binds)
    }

    private func filesFor(_ contentIds: [Int64], _ f: SearchFilters) throws -> [Int64: FileInfo] {
        var out: [Int64: FileInfo] = [:]
        let c = Self.clauses(f)
        for start in stride(from: 0, to: contentIds.count, by: 400) {
            let chunk = Array(contentIds[start..<min(start + 400, contentIds.count)])
            let sql = "select content_id, kind, path, mtime from files where status = 'indexed' and content_id in ("
                + Array(repeating: "?", count: chunk.count).joined(separator: ",") + ")" + c.sql
            let binds: [Bind] = chunk.map { .int($0) } + c.binds
            for (contentId, kind, path, mtime) in try store.query(sql, binds, { ($0.int(0), $0.text(1), $0.text(2), $0.int(3)) }) {
                var info = out[contentId] ?? FileInfo(kind: kind, paths: [], modified: 0)
                info.paths.append(path)
                info.modified = max(info.modified, mtime)
                out[contentId] = info
            }
        }
        return out
    }
}
