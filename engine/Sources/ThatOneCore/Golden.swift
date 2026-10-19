import Foundation

public struct GoldenQuery: Codable, Equatable {
    public let id: String
    public let query: String
    public let tag: String
    public let relevant: [String]
    public let kinds: [String]?       // searched with these kinds (code needs ["code"]); nil = a default search
    public init(id: String, query: String, tag: String, relevant: [String], kinds: [String]? = nil) {
        self.id = id; self.query = query; self.tag = tag; self.relevant = relevant; self.kinds = kinds
    }
}

public struct EvalCell: Equatable {
    public var hit10: Double
    public var mrr: Double
    public var n: Int
}

public struct EvalSummary: Equatable {
    public var byTag: [String: EvalCell]
    public var overall: EvalCell
    public var misses: [String]
    public var unindexed: [String]
    public var searchMs: [Double] = []
}

public enum Golden {
    public static func load(_ url: URL) throws -> [GoldenQuery] {
        try JSONDecoder().decode([GoldenQuery].self, from: Data(contentsOf: url))
    }

    /// `hits` holds one list of paths per result, best first. A query hits when any path of any of the first `k`
    /// results is relevant; the reciprocal rank is 1 / (position + 1) of that first result.
    public static func score(hits: [[String]], relevant: Set<String>, k: Int = 10) -> (hit: Bool, reciprocalRank: Double) {
        for (position, paths) in hits.prefix(k).enumerated() where paths.contains(where: relevant.contains) {
            return (true, 1.0 / Double(position + 1))
        }
        return (false, 0)
    }

    public static func evaluate(engine: Engine, queries: [GoldenQuery], tags: Set<String>? = nil, k: Int = 10) throws -> EvalSummary {
        var sums: [String: (hits: Double, rr: Double, n: Int)] = [:]
        var misses: [String] = []
        var unindexed: [String] = []
        let selected = queries.filter { tags?.contains($0.tag) ?? true }
        var times: [Double] = []
        if let first = selected.first { _ = try? engine.search(first.query, limit: 1) }   // loads the model; not timed
        for q in selected {
            let relevant = Set(q.relevant.map(RealPath.of))
            for path in relevant.sorted() {
                let indexed = try engine.store.fileRecord(path: path)?.status == "indexed"
                if !indexed { unindexed.append("\(q.id)→\(path)") }
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let response = try engine.search(q.query, filters: SearchFilters(kinds: Set(q.kinds ?? [])), limit: k)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let result = score(hits: response.hits.map { $0.paths }, relevant: relevant, k: k)
            if !result.hit { misses.append(q.id) }
            for key in [q.tag, "all"] {
                var cell = sums[key] ?? (0, 0, 0)
                cell.hits += result.hit ? 1 : 0
                cell.rr += result.reciprocalRank
                cell.n += 1
                sums[key] = cell
            }
        }
        func cell(_ key: String) -> EvalCell {
            let s = sums[key] ?? (0, 0, 0)
            return s.n == 0 ? EvalCell(hit10: 0, mrr: 0, n: 0) : EvalCell(hit10: s.hits / Double(s.n), mrr: s.rr / Double(s.n), n: s.n)
        }
        var byTag: [String: EvalCell] = [:]
        for key in sums.keys where key != "all" { byTag[key] = cell(key) }
        return EvalSummary(byTag: byTag, overall: cell("all"), misses: misses, unindexed: unindexed, searchMs: times)
    }

    /// The value at or below which `p` (0...1) of `values` fall; 0 for none.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)
        return sorted[min(index, sorted.count - 1)]
    }

    public static func format(_ summary: EvalSummary) -> String {
        var lines = ["tag        hit@10   mrr     n"]
        for (tag, c) in summary.byTag.sorted(by: { $0.key < $1.key }) {
            lines.append(String(format: "%-10@ %.3f    %.3f   %d", tag as NSString, c.hit10, c.mrr, c.n))
        }
        let o = summary.overall
        lines.append(String(format: "%-10@ %.3f    %.3f   %d", "all" as NSString, o.hit10, o.mrr, o.n))
        if !summary.searchMs.isEmpty {
            lines.append(String(format: "search ms: p50 %.0f, p95 %.0f, max %.0f (n %d)", percentile(summary.searchMs, 0.5),
                                percentile(summary.searchMs, 0.95), summary.searchMs.max() ?? 0, summary.searchMs.count))
        }
        if !summary.misses.isEmpty { lines.append("misses: " + summary.misses.joined(separator: ", ")) }
        if !summary.unindexed.isEmpty { lines.append("relevant files with no indexed row (guaranteed misses): " + summary.unindexed.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
