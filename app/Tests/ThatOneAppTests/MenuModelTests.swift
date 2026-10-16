import ThatOneCore
import XCTest
@testable import ThatOneApp

final class MenuModelTests: XCTestCase {
    func titles(_ s: HostSnapshot) -> [String: String] {
        Dictionary(uniqueKeysWithValues: MenuModel.items(for: s, hotKey: .default).map { ($0.id, $0.title) })
    }

    func testIdleMenuShowsCountsAndHasNoFailedItem() {
        var s = HostSnapshot(); s.state = .idle; s.files = ["indexed": 286]
        let t = titles(s)
        XCTAssertEqual(t["open"], "Search  ⌃⌥Space")
        XCTAssertEqual(t["status"], "Up to date · 286 images")
        XCTAssertEqual(t["pause"], "Pause indexing")
        XCTAssertNil(t["failed"])
        XCTAssertEqual(MenuModel.items(for: s, hotKey: .default).map { $0.id }, ["open", "status", "pause", "window", "folders", "settings", "quit"])
    }

    func testIndexingAndPausedStatuses() {
        var s = HostSnapshot(); s.state = .indexing(done: 12, waiting: 28)
        XCTAssertEqual(titles(s)["status"], "Indexing 12 of 40")
        s.state = .pausedByUser
        XCTAssertEqual(titles(s)["status"], "Paused by you")
        XCTAssertEqual(titles(s)["pause"], "Resume indexing")
        s.state = .paused("Low Power Mode is on")
        XCTAssertEqual(titles(s)["status"], "Paused: Low Power Mode is on")
        XCTAssertEqual(titles(s)["pause"], "Pause indexing")
        s.state = .starting
        XCTAssertEqual(titles(s)["status"], "Starting…")
    }

    func testFailedFilesItemAppearsWithTheCount() {
        var s = HostSnapshot(); s.state = .idle; s.queue = ServiceQueue(queued: 0, running: 0, failed: 3)
        XCTAssertEqual(titles(s)["failed"], "3 files could not be indexed…")
        s.queue = ServiceQueue(queued: 0, running: 0, failed: 1)
        XCTAssertEqual(titles(s)["failed"], "1 file could not be indexed…")
    }

    func testHotKeyProblemIsShownInTheMenu() {
        var s = HostSnapshot(); s.state = .idle; s.hotKeyProblem = "already in use by another app"
        XCTAssertEqual(titles(s)["open"], "Search (hotkey unavailable: already in use by another app)")
    }

    func testFolderCandidatesAreOnlyTheExistingStandardFolders() throws {
        let home = Fixtures.tempDir("home")
        for name in ["Desktop", "Pictures", "Library", "Secrets"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(FolderCandidates.existing(home: home.path), ["\(home.path)/Pictures", "\(home.path)/Desktop"])
    }

    func testPhotosLineReflectsTheState() {
        var s = HostSnapshot(); s.state = .idle
        XCTAssertNil(titles(s)["photos"])
        s.photos = .needsPermission
        XCTAssertEqual(titles(s)["photos"], "Apple Photos: needs permission…")
        s.photos = .denied
        XCTAssertEqual(titles(s)["photos"], "Apple Photos: access denied (open Settings)…")
        s.photos = .on(limited: true); s.photosCount = 1234
        XCTAssertEqual(titles(s)["photos"], "Apple Photos: 1234 photos (limited access)")
        s.photos = .restricted
        XCTAssertEqual(MenuModel.items(for: s, hotKey: .default).first { $0.id == "photos" }?.enabled, false)
        XCTAssertEqual(MenuModel.items(for: s, hotKey: .default).map { $0.id }.prefix(4), ["open", "status", "photos", "pause"])
    }

    func testKindsLineShowsPDFAndDocumentCountsBeforePhotos() {
        var s = HostSnapshot(); s.state = .idle
        XCTAssertNil(titles(s)["kinds"])
        s.kinds = ["image": 40, "pdf": 12, "document": 1]
        XCTAssertEqual(titles(s)["kinds"], "12 PDFs, 1 document")
        s.kinds = ["pdf": 1]; s.photos = .on(limited: false); s.photosCount = 5
        XCTAssertEqual(titles(s)["kinds"], "1 PDF, 0 documents")
        XCTAssertEqual(MenuModel.items(for: s, hotKey: .default).map { $0.id }.prefix(5), ["open", "status", "kinds", "photos", "pause"])
        XCTAssertEqual(MenuModel.items(for: s, hotKey: .default).first { $0.id == "kinds" }?.enabled, false)
    }
}
