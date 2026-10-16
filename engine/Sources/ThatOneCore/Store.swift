import CVec
import Foundation
import SQLCipher

public enum ThatOneCore { public static let version = "0.1.0-m1a" }

public enum StoreError: Error, Equatable {
    case open(String)
    case wrongKeyOrNotDatabase
    case badKey
    case sql(String)
    case dimensionMismatch(stored: Int, requested: Int)
    case unsupportedSchema(Int)
    case badVector(expected: Int, got: Int)
}

public enum Bind {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

public struct Row {
    let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

private typealias DestructorType = @convention(c) (UnsafeMutableRawPointer?) -> Void
private let transient = unsafeBitCast(-1, to: DestructorType.self)   // SQLITE_TRANSIENT

/// One encrypted SQLite connection (SQLCipher) with sqlite-vec registered. Calls are serialised by a lock.
public final class Store {
    public let path: String
    public internal(set) var dim = 0
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var txDepth = 0

    public init(path: String, key: Data) throws {
        guard key.count == 32 else { throw StoreError.badKey }
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(rc))"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)      // another thatone process may be writing; wait instead of failing at once
        do {
            let hex = key.map { String(format: "%02x", $0) }.joined()
            try run("PRAGMA key = \"x'\(hex)'\"")
            do { _ = try query("select count(*) from sqlite_master") { $0.int(0) } }
            catch {
                // only "file is not a database" means a wrong key; a busy or I/O error must not blame the key
                if sqlite3_errcode(handle) == SQLITE_NOTADB { throw StoreError.wrongKeyOrNotDatabase }
                throw error
            }
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_vec_init(handle, &err, nil) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "sqlite-vec init failed"
                sqlite3_free(err)
                throw StoreError.sql(message)
            }
            try run("PRAGMA journal_mode = WAL")
            try run("PRAGMA temp_store = MEMORY")    // keep sort and merge spill out of unencrypted temp files
            try run("PRAGMA foreign_keys = ON")
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// A statement as it may appear in an error message: truncated, and never the key.
    static func describeSQL(_ sql: String) -> String {
        sql.hasPrefix("PRAGMA key") ? "PRAGMA key" : String(sql.prefix(80))
    }

    public static func vectorBlob(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian float32 on arm64
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql("\(String(cString: sqlite3_errmsg(db))) in: \(Store.describeSQL(sql))")
        }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch b {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                rc = v.isEmpty ? sqlite3_bind_zeroblob(stmt, idx, 0)
                    : v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmt)
                throw StoreError.sql("bind \(i + 1): \(message)")
            }
        }
        return stmt
    }

    @discardableResult
    public func run(_ sql: String, _ binds: [Bind] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { continue }
            if rc == SQLITE_DONE { break }
            throw StoreError.sql("\(String(cString: sqlite3_errmsg(db))) in: \(Store.describeSQL(sql))")
        }
        return Int(sqlite3_changes(db))
    }

    public func query<T>(_ sql: String, _ binds: [Bind] = [], _ map: (Row) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError.sql("\(String(cString: sqlite3_errmsg(db))) in: \(Store.describeSQL(sql))") }
        }
        return out
    }

    public func int(_ sql: String, _ binds: [Bind] = []) throws -> Int64? {
        try query(sql, binds) { $0.int(0) }.first
    }

    public var lastInsertRowId: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(db)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let outermost = txDepth == 0
        if outermost { try run("BEGIN IMMEDIATE") }
        txDepth += 1
        defer { txDepth -= 1 }
        do {
            let result = try body()
            if outermost { try run("COMMIT") }
            return result
        } catch {
            if outermost { _ = try? run("ROLLBACK") }
            throw error
        }
    }
}
