import Foundation

public struct GoldenQuery: Codable, Equatable {
    public let id: String
    public let query: String
    public let tag: String
    public let relevant: [String]
    public init(id: String, query: String, tag: String, relevant: [String]) {
        self.id = id; self.query = query; self.tag = tag; self.relevant = relevant
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
        for q in queries where tags?.contains(q.tag) ?? true {
            let relevant = Set(q.relevant.map(RealPath.of))
            for path in relevant.sorted() {
                let indexed = try engine.store.fileRecord(path: path)?.status == "indexed"
                if !indexed { unindexed.append("\(q.id)→\(path)") }
            }
            let response = try engine.search(q.query, limit: k)
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
        return EvalSummary(byTag: byTag, overall: cell("all"), misses: misses, unindexed: unindexed)
    }

    public static func format(_ summary: EvalSummary) -> String {
        var lines = ["tag        hit@10   mrr     n"]
        for (tag, c) in summary.byTag.sorted(by: { $0.key < $1.key }) {
            lines.append(String(format: "%-10@ %.3f    %.3f   %d", tag as NSString, c.hit10, c.mrr, c.n))
        }
        let o = summary.overall
        lines.append(String(format: "%-10@ %.3f    %.3f   %d", "all" as NSString, o.hit10, o.mrr, o.n))
        if !summary.misses.isEmpty { lines.append("misses: " + summary.misses.joined(separator: ", ")) }
        if !summary.unindexed.isEmpty { lines.append("relevant files with no indexed row (guaranteed misses): " + summary.unindexed.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
