import Foundation

public struct SegmentInput {
    public var modality: String   // "text" | "image" (audio and frame arrive in later milestones)
    public var anchor: String     // JSON object, e.g. {} or {"page":3}
    public var text: String
    public var vector: [Float]
    public init(modality: String, anchor: String = "{}", text: String, vector: [Float]) {
        self.modality = modality; self.anchor = anchor; self.text = text; self.vector = vector
    }
}

public struct FileRecord: Equatable {
    public let id: Int64
    public let path: String
    public let contentId: Int64?
    public let kind: String
    public let size: Int64
    public let mtime: Int64
    public let status: String   // indexed | skipped | failed
    public let note: String
}

public struct ContentRecord: Equatable {
    public let id: Int64
    public let status: String
    public let note: String
}

public struct StoreCounts: Equatable {
    public var filesByStatus: [String: Int]
    public var segmentsByModality: [String: Int]
    public var contents: Int
    public var filesByKind: [String: Int] = [:]      // indexed files only
}

extension Store {
    public func contentByHash(_ hash: String) throws -> ContentRecord? {
        try query("select id, status, note from contents where hash = ?", [.text(hash)]) {
            ContentRecord(id: $0.int(0), status: $0.text(1), note: $0.text(2))
        }.first
    }

    /// Inserts a content row with its segments, FTS rows and vectors in one transaction.
    @discardableResult
    public func addContent(hash: String, kind: String, status: String, note: String = "",
                           segments: [SegmentInput], now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Int64 {
        for s in segments where s.vector.count != dim {
            throw StoreError.badVector(expected: dim, got: s.vector.count)
        }
        return try transaction {
            try run("insert into contents(hash, kind, status, note, indexed_at) values (?, ?, ?, ?, ?)",
                    [.text(hash), .text(kind), .text(status), .text(note), .int(now)])
            let contentId = lastInsertRowId
            for s in segments {
                try run("insert into segments(content_id, modality, anchor, text) values (?, ?, ?, ?)",
                        [.int(contentId), .text(s.modality), .text(s.anchor), .text(s.text)])
                let segmentId = lastInsertRowId
                try run("insert into segments_fts(rowid, text) values (?, ?)", [.int(segmentId), .text(s.text)])
                try run("insert into segment_vectors(rowid, embedding) values (?, ?)",
                        [.int(segmentId), .blob(Store.vectorBlob(s.vector))])
            }
            return contentId
        }
    }

    public func upsertFile(path: String, contentId: Int64?, kind: String, size: Int64, mtime: Int64,
                           status: String, note: String = "",
                           now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try transaction {
            let previous = try fileRecord(path: path)?.contentId
            let contentBind: Bind = contentId.map { Bind.int($0) } ?? Bind.null
            try run("""
                insert into files(path, content_id, kind, size, mtime, status, note, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?)
                on conflict(path) do update set content_id = excluded.content_id, kind = excluded.kind,
                    size = excluded.size, mtime = excluded.mtime, status = excluded.status,
                    note = excluded.note, updated_at = excluded.updated_at
                """, [.text(path), contentBind, .text(kind), .int(size), .int(mtime), .text(status), .text(note), .int(now)])
            if let previous, previous != contentId { try deleteContentIfOrphan(previous) }
        }
    }

    public func fileRecord(path: String) throws -> FileRecord? {
        try query("select id, path, content_id, kind, size, mtime, status, note from files where path = ?",
                  [.text(path)]) {
            FileRecord(id: $0.int(0), path: $0.text(1), contentId: $0.isNull(2) ? nil : $0.int(2),
                       kind: $0.text(3), size: $0.int(4), mtime: $0.int(5), status: $0.text(6), note: $0.text(7))
        }.first
    }

    @discardableResult
    public func removeFile(path: String) throws -> Bool {
        try transaction {
            guard let record = try fileRecord(path: path) else { return false }
            try run("delete from files where id = ?", [.int(record.id)])
            if let contentId = record.contentId { try deleteContentIfOrphan(contentId) }
            return true
        }
    }

    /// Deletes a content row and everything hanging off it once no file points at it.
    func deleteContentIfOrphan(_ contentId: Int64) throws {
        guard try int("select count(*) from files where content_id = ?", [.int(contentId)]) == 0 else { return }
        let segmentIds = try query("select id from segments where content_id = ?", [.int(contentId)]) { $0.int(0) }
        for id in segmentIds {   // virtual tables have no cascade and no reliable `rowid in (subquery)`
            try run("delete from segment_vectors where rowid = ?", [.int(id)])
            try run("delete from segments_fts where rowid = ?", [.int(id)])
        }
        try run("delete from segments where content_id = ?", [.int(contentId)])
        try run("delete from contents where id = ?", [.int(contentId)])
    }

    /// Paths under `folder`, matched as a literal prefix (no LIKE wildcards, case-sensitive).
    /// Files of one kind, apart from Apple Photos rows (which are images too but have their own switch).
    public func filePaths(ofKind kind: String) throws -> [String] {
        try query("select path from files where kind = ? and substr(path, 1, 7) <> 'photos:' order by path", [.text(kind)]) { $0.text(0) }
    }

    /// Paths that start with `prefix` literally (no slash added): used for the `photos:` virtual paths.
    public func filePaths(withPrefix prefix: String) throws -> [String] {
        try query("select path from files where substr(path, 1, ?) = ? order by path",
                  [.int(Int64(prefix.unicodeScalars.count)), .text(prefix)]) { $0.text(0) }
    }

    public func filePaths(under folder: String) throws -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return try query("select path from files where substr(path, 1, ?) = ? order by path",
                         [.int(Int64(prefix.unicodeScalars.count)), .text(prefix)]) { $0.text(0) }
    }

    public func counts() throws -> StoreCounts {
        var files: [String: Int] = [:]
        for (status, n) in try query("select status, count(*) from files group by status", [], { ($0.text(0), Int($0.int(1))) }) {
            files[status] = n
        }
        var segments: [String: Int] = [:]
        for (modality, n) in try query("select modality, count(*) from segments group by modality", [], { ($0.text(0), Int($0.int(1))) }) {
            segments[modality] = n
        }
        var kinds: [String: Int] = [:]
        for (kind, n) in try query("select kind, count(*) from files where status = 'indexed' group by kind", [], { ($0.text(0), Int($0.int(1))) }) {
            kinds[kind] = n
        }
        return StoreCounts(filesByStatus: files, segmentsByModality: segments,
                           contents: Int(try int("select count(*) from contents") ?? 0), filesByKind: kinds)
    }

    /// Starts the note of an indexed file the engine gave up on: its last indexed content stays searchable.
    public static let keptAfterFailure = "failed (showing the last indexed version): "

    /// Whether `record` is an indexed file kept after a failure (read again on its next claim, never "unchanged").
    static func isKeptAfterFailure(_ record: FileRecord) -> Bool {
        record.status == "indexed" && record.note.hasPrefix(keptAfterFailure)
    }

    /// Failed files, and indexed files kept after a failure.
    public func failedFiles() throws -> [(path: String, note: String)] {
        try query("select path, note from files where status = 'failed' or (status = 'indexed' and substr(note, 1, ?) = ?) order by path",
                  [.int(Int64(Self.keptAfterFailure.unicodeScalars.count)), .text(Self.keptAfterFailure)]) { (path: $0.text(0), note: $0.text(1)) }
    }
}
