import XCTest
@testable import ThatOneCore

final class StoreStackTests: XCTestCase {
    func testVersions() throws {
        let dir = TestSupport.tempDir()
        let s = try Store(path: dir.appendingPathComponent("a.db").path, key: TestSupport.key)
        XCTAssertEqual(try s.query("select vec_version()") { $0.text(0) }, ["v0.1.9"])
        XCTAssertEqual(try s.query("PRAGMA cipher_version") { $0.text(0) }, ["4.19.0 community"])
    }

    func testFileIsEncryptedAndReopensWithSameKey() throws {
        let path = TestSupport.tempDir().appendingPathComponent("a.db").path
        do {
            let s = try Store(path: path, key: TestSupport.key)
            try s.run("create table t(x text)")
            try s.run("insert into t values (?)", [.text("secret words")])
            s.close()
        }
        let head = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        XCTAssertNotEqual(String(data: head, encoding: .utf8), "SQLite format 3\0")
        XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: Data("secret words".utf8)))
        let again = try Store(path: path, key: TestSupport.key)
        XCTAssertEqual(try again.query("select x from t") { $0.text(0) }, ["secret words"])
    }

    func testWrongKeyIsRejected() throws {
        let path = TestSupport.tempDir().appendingPathComponent("a.db").path
        let s = try Store(path: path, key: TestSupport.key)
        try s.run("create table t(x)")
        s.close()
        XCTAssertThrowsError(try Store(path: path, key: TestSupport.otherKey)) {
            XCTAssertEqual($0 as? StoreError, .wrongKeyOrNotDatabase)
        }
    }

    func testPlaintextDatabaseIsRejectedNotReadAsPlaintext() throws {
        let path = TestSupport.tempDir().appendingPathComponent("plain.db").path
        try Data("SQLite format 3\0 not really".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Store(path: path, key: TestSupport.key)) {
            XCTAssertEqual($0 as? StoreError, .wrongKeyOrNotDatabase)
        }
    }

    func testKeyMustBe32Bytes() {
        let path = TestSupport.tempDir().appendingPathComponent("a.db").path
        XCTAssertThrowsError(try Store(path: path, key: Data(repeating: 1, count: 16))) {
            XCTAssertEqual($0 as? StoreError, .badKey)
        }
    }

    func testFTS5KeepsIndicWordsWhole() throws {
        let s = try Store(path: TestSupport.tempDir().appendingPathComponent("a.db").path, key: TestSupport.key)
        try s.run("create virtual table f using fts5(body, tokenize = \"unicode61 categories 'L* N* Co M*'\")")
        try s.run("insert into f(body) values (?), (?)", [.text("ಬೆಂಗಳೂರು ಮನೆ ದಾಖಲೆ"), .text("दस्तावेज़ पाइप")])
        func count(_ q: String) throws -> Int64 {
            try s.int("select count(*) from f where f match ?", [.text(q)]) ?? -1
        }
        XCTAssertEqual(try count("\"ಬೆಂಗಳೂರು\""), 1)
        XCTAssertEqual(try count("\"दस्तावेज़\""), 1)
        XCTAssertEqual(try count("\"ಬ\""), 0)        // a fragment must not match a whole word
    }

    func testVecCosineKNNWithBlobParameter() throws {
        let s = try Store(path: TestSupport.tempDir().appendingPathComponent("a.db").path, key: TestSupport.key)
        try s.run("create virtual table v using vec0(embedding float[4] distance_metric=cosine)")
        let vectors: [[Float]] = [[1, 0, 0, 0], [0.7, 0.7, 0, 0], [0, 1, 0, 0]]
        for (i, v) in vectors.enumerated() {
            try s.run("insert into v(rowid, embedding) values (?, ?)", [.int(Int64(i + 1)), .blob(Store.vectorBlob(v))])
        }
        let ids = try s.query("select rowid from v where embedding match ? and k = 3 order by distance",
                              [.blob(Store.vectorBlob([1, 0.1, 0, 0]))]) { $0.int(0) }
        XCTAssertEqual(ids, [1, 2, 3])
    }

    func testTransactionRollsBackAndNests() throws {
        let s = try Store(path: TestSupport.tempDir().appendingPathComponent("a.db").path, key: TestSupport.key)
        try s.run("create table t(x integer)")
        struct Boom: Error {}
        XCTAssertThrowsError(try s.transaction {
            try s.run("insert into t values (1)")
            try s.transaction { try s.run("insert into t values (2)") }
            throw Boom()
        })
        XCTAssertEqual(try s.int("select count(*) from t"), 0)
        try s.transaction { try s.transaction { try s.run("insert into t values (3)") } }
        XCTAssertEqual(try s.int("select count(*) from t"), 1)
    }

    func testTempFilesStayInMemory() throws {
        let s = try Store(path: TestSupport.tempDir().appendingPathComponent("a.db").path, key: TestSupport.key)
        XCTAssertEqual(try s.int("PRAGMA temp_store"), 2)          // 2 = MEMORY: sorts and merges never spill to temp files
    }

    func testSQLDescriptionsNeverContainTheKey() {
        let statement = "PRAGMA key = \"x'" + String(repeating: "ab", count: 32) + "'\""
        XCTAssertEqual(Store.describeSQL(statement), "PRAGMA key")
        XCTAssertEqual(Store.describeSQL(String(repeating: "x", count: 200)).count, 80)
    }

    func testSecondConnectionWaitsForABusyDatabaseInsteadOfFailing() throws {
        let path = TestSupport.tempDir().appendingPathComponent("a.db").path
        let a = try Store(path: path, key: TestSupport.key)
        try a.run("create table t(x integer)")
        let b = try Store(path: path, key: TestSupport.key)
        DispatchQueue.global().async {
            try? a.transaction {
                try a.run("insert into t values (1)")
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNoThrow(try b.run("insert into t values (2)"))   // waits for the writer; "database is locked" would throw
        XCTAssertEqual(try b.int("select count(*) from t"), 2)
    }
}
