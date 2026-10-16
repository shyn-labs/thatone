import XCTest
@testable import ThatOneCore

final class PathRulesTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(Kinds.detect("/a/B.PNG"), "image")
        XCTAssertEqual(Kinds.detect("/a/photo.HEIC"), "image")
        XCTAssertEqual(Kinds.detect("/a/shot.jpeg"), "image")
        XCTAssertEqual(Kinds.detect("/a/report.pdf"), "pdf")
        XCTAssertNil(Kinds.detect("/a/noextension"))
    }

    func testExcludedPaths() {
        let excl = Exclusions()
        for rel in [".ssh/id_ed25519", ".aws/credentials", "proj/.env", "proj/.env.local", "certs/server.pem",
                    "k/private.key", "proj/node_modules/x.png", "proj/.git/HEAD", "Foo.app/Contents/x.png",
                    "Photos Library.photoslibrary/originals/a.jpg", "docs/.report.png.icloud", "Library/Caches/a.png"] {
            XCTAssertTrue(excl.isExcluded(path: "/Users/v/" + rel), rel)
        }
        XCTAssertFalse(excl.isExcluded(path: "/Users/v/Pictures/screens/shot 1.png"))
    }

    func testRootInsideLibraryIsNotExcludedByItsAncestors() {
        let root = "/Users/v/Library/Mobile Documents/com~apple~CloudDocs"
        let excl = Exclusions()
        XCTAssertFalse(excl.isExcluded(path: root + "/scan.png", root: root))
        XCTAssertTrue(excl.isExcluded(path: root + "/.ssh/key.png", root: root))
        XCTAssertTrue(excl.isExcluded(path: root + "/scan.png"))          // without the root, Library excludes it
    }

    func testUserPrefixesMatchWholeDirectoriesOnly() {
        let excl = Exclusions(extraPrefixes: ["/Users/v/Private"])
        XCTAssertTrue(excl.isExcluded(path: "/Users/v/Private/a.png"))
        XCTAssertFalse(excl.isExcluded(path: "/Users/v/Privateer/a.png"))
    }

    func testSecretGateCatchesRealTokensNotProse() {
        XCTAssertTrue(SecretGate.containsSecret("Your token cfat_K38VwN4gA780TJFA40XVJAmKJFKE6p1DME6TdBR80"))
        XCTAssertTrue(SecretGate.containsSecret("token ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertTrue(SecretGate.containsSecret("key sk-ant-api03-abcdefghijklmnopqrstuvwx"))
        XCTAssertTrue(SecretGate.containsSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(SecretGate.containsSecret("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertFalse(SecretGate.containsSecret("The GitHub token is stored in the keychain, never in a file."))
        XCTAssertFalse(SecretGate.containsSecret("pip install sk-learn and akia is a name"))
        XCTAssertFalse(SecretGate.containsSecret(""))
    }

    func testRealPathResolvesPrivateVarAndKeepsMissingPaths() {
        XCTAssertTrue(RealPath.of(FileManager.default.temporaryDirectory.path).hasPrefix("/private/var/"))
        XCTAssertEqual(RealPath.of("/nonexistent/a/../b.png"), "/nonexistent/b.png")
    }

    func testRealPathResolvesTheExistingAncestorOfAMissingPath() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertEqual(RealPath.of(tmp + "/nope/a/../b.png"), RealPath.of(tmp) + "/nope/b.png")
        XCTAssertTrue(RealPath.of(tmp + "/nope/b.png").hasPrefix("/private/var/"))
        XCTAssertEqual(RealPath.of("/definitely-missing/x/./y.png"), "/definitely-missing/x/y.png")
    }
}
