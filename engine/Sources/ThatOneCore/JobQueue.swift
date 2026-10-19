import Foundation

public struct QueueCounts: Equatable {
    public var queued: Int
    public var running: Int
    public var failed: Int
}

public final class JobQueue {
    public static let maxAttempts = 3
    /// The error of a job found `running` at startup: the app stopped (crashed or was quit) while reading the file.
    public static let crashNote = "stopped the app while reading"
    /// The priority of a purge job: the scan no longer sees the file, so its rows are dropped (it runs last).
    public static let purgePriority = Int64.min

    private let store: Store
    private let clock: () -> Int64

    public init(store: Store, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.store = store
        self.clock = clock
    }

    /// Queues `path`. A job that is already running is left alone: the next scan notices a changed mtime and queues
    /// the file again.
    public func enqueue(path: String, priority: Int64) throws {
        try store.run("""
            insert into jobs(path, priority, state) values (?, ?, 'queued')
            on conflict(path) do update set
                priority = excluded.priority,
                attempts = case when jobs.state = 'running' then jobs.attempts else 0 end,
                next_attempt = case when jobs.state = 'running' then jobs.next_attempt else 0 end,
                last_error = case when jobs.state = 'running' then jobs.last_error else '' end,
                state = case when jobs.state = 'running' then 'running' else 'queued' end
            """, [.text(path), .int(priority)])
    }

    /// Puts a claimed job back without counting an attempt (the environment, not the file, was the problem).
    public func requeue(path: String, delaySeconds: Int64) throws {
        try store.run("update jobs set state = 'queued', next_attempt = ? where path = ?",
                      [.int(clock() + delaySeconds), .text(path)])
    }

    /// Up to `limit` queued paths whose back-off has passed, highest priority first; they become `running`.
    /// `skippingExtensions`: file paths ending in one of these (any case) stay queued for another process (the app owns
    /// audio and video when this one has no speech model). Photos paths are never skipped: they are triaged as assets.
    public func claim(limit: Int, skippingExtensions: Set<String> = []) throws -> [String] {
        let now = clock()
        let skip = Self.skipClause(skippingExtensions)
        return try store.transaction {
            let paths = try store.query(
                "select path from jobs where state = 'queued' and next_attempt <= ?" + skip.sql + " order by priority desc, path limit ?",
                [.int(now)] + skip.binds + [.int(Int64(limit))]) { $0.text(0) }
            for path in paths { try store.run("update jobs set state = 'running' where path = ?", [.text(path)]) }
            return paths
        }
    }

    /// Queued jobs `claim` with the same `skippingExtensions` would take, now or after their back-off.
    public func claimableCount(skippingExtensions: Set<String> = []) throws -> Int {
        let skip = Self.skipClause(skippingExtensions)
        return Int(try store.int("select count(*) from jobs where state = 'queued'" + skip.sql, skip.binds) ?? 0)
    }

    /// SQL (" and ...") that leaves out file paths ending in ".<ext>" for any of `extensions`, in any case.
    private static func skipClause(_ extensions: Set<String>) -> (sql: String, binds: [Bind]) {
        var sql = ""
        var binds: [Bind] = []
        for ext in extensions.sorted() where !ext.isEmpty {
            let literal = ext.lowercased().replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            // "/x/.mp4" is a hidden file with no extension, not an mp4.
            sql += " and (substr(path, 1, ?) = ? or not (lower(path) like ? escape '\\' and lower(path) not like ? escape '\\'))"
            binds += [.int(Int64(PhotosPath.scheme.count)), .text(PhotosPath.scheme), .text("%." + literal), .text("%/." + literal)]
        }
        return (sql, binds)
    }

    public func complete(path: String) throws {
        try store.run("delete from jobs where path = ?", [.text(path)])
    }

    public func fail(path: String, error: String) throws {
        let now = clock()
        try store.transaction {
            let attempts = (try store.int("select attempts from jobs where path = ?", [.text(path)]) ?? 0) + 1
            if attempts >= Int64(Self.maxAttempts) {
                try store.run("update jobs set state = 'failed', attempts = ?, last_error = ? where path = ?",
                              [.int(attempts), .text(error), .text(path)])
            } else {
                let delay = min(Int64(30) * (Int64(1) << (attempts - 1)), 3600)   // 30 s, 60 s, ...
                try store.run("update jobs set state = 'queued', attempts = ?, next_attempt = ?, last_error = ? where path = ?",
                              [.int(attempts), .int(now + delay), .text(error), .text(path)])
            }
        }
    }

    /// After a crash or force-quit, jobs left `running` go back to the queue, each counting one attempt: the file may be
    /// what stopped the app. A job found `running` after the previous restart already recovered it (its error is still
    /// `crashNote`) is given up as failed with `crashNote`, as is one that reaches `maxAttempts`; it is never claimed
    /// again until the file changes or the user retries failed files. A purge job (`purgePriority`: the file is gone)
    /// just runs again: no attempt, no failure. A normal quit leaves nothing `running` (see `release`). Returns the paths
    /// given up.
    @discardableResult
    public func recoverRunning() throws -> [String] {
        try store.transaction {
            try store.run("update jobs set state = 'queued' where state = 'running' and priority = ?", [.int(Self.purgePriority)])
            let failed = try store.query(
                "select path from jobs where state = 'running' and (last_error = ? or attempts + 1 >= ?) order by path",
                [.text(Self.crashNote), .int(Int64(Self.maxAttempts))]) { $0.text(0) }
            try store.run("""
                update jobs set attempts = attempts + 1, last_error = ?,
                    state = case when last_error = ? or attempts + 1 >= ? then 'failed' else 'queued' end
                where state = 'running'
                """, [.text(Self.crashNote), .text(Self.crashNote), .int(Int64(Self.maxAttempts))])
            return failed
        }
    }

    /// The highest-priority job recovered after a crash that has not run to the end since (still queued with
    /// `crashNote`), claimed alone: if it stops the app again, only that file is blamed. Empty when there is none.
    public func claimRecovered(skippingExtensions: Set<String> = []) throws -> [String] {
        let now = clock()
        let skip = Self.skipClause(skippingExtensions)
        return try store.transaction {
            let paths = try store.query(
                "select path from jobs where state = 'queued' and last_error = ? and next_attempt <= ?" + skip.sql
                    + " order by priority desc, path limit 1",
                [.text(Self.crashNote), .int(now)] + skip.binds) { $0.text(0) }
            for path in paths { try store.run("update jobs set state = 'running' where path = ?", [.text(path)]) }
            return paths
        }
    }

    /// Puts claimed jobs that are still `running` back in the queue as they were (attempts, error and back-off kept):
    /// the app is quitting normally, which says nothing about the files. One short write.
    public func release(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try store.transaction {
            for path in paths { try store.run("update jobs set state = 'queued' where path = ? and state = 'running'", [.text(path)]) }
        }
    }

    public func retryFailed() throws {
        try store.run("update jobs set state = 'queued', attempts = 0, next_attempt = 0 where state = 'failed'")
    }

    public func counts() throws -> QueueCounts {
        func count(_ state: String) throws -> Int {
            Int(try store.int("select count(*) from jobs where state = ?", [.text(state)]) ?? 0)
        }
        return QueueCounts(queued: try count("queued"), running: try count("running"), failed: try count("failed"))
    }

    public func failedJobs() throws -> [(path: String, error: String)] {
        try store.query("select path, last_error from jobs where state = 'failed' order by path") {
            (path: $0.text(0), error: $0.text(1))
        }
    }
}

extension JobQueue {
    public func remove(path: String) throws { try store.run("delete from jobs where path = ?", [.text(path)]) }

    /// Drops every job whose path starts with `prefix` literally.
    public func remove(withPrefix prefix: String) throws {
        try store.run("delete from jobs where substr(path, 1, ?) = ?", [.int(Int64(prefix.unicodeScalars.count)), .text(prefix)])
    }

    /// Drops every queued job under `folder` (literal prefix).
    public func remove(under folder: String) throws {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        try store.run("delete from jobs where substr(path, 1, ?) = ?", [.int(Int64(prefix.unicodeScalars.count)), .text(prefix)])
    }
}
