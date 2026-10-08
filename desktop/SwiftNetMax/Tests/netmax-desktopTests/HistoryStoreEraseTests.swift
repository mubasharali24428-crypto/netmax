import XCTest
@testable import netmax_desktop

final class HistoryStoreEraseTests: XCTestCase {
    private var tempDir: URL!
    private var historyURL: URL!
    private var sentinelURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-store-erase-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        historyURL = tempDir.appendingPathComponent("history.jsonl")
        sentinelURL = tempDir.appendingPathComponent("unrelated_sentinel.txt")
        try! "sentinel-contents".write(to: sentinelURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        // Restore permissions if needed before deleting
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEraseAllRemovesAllFourArtifactsAndPreservesSentinel() throws {
        let store = HistoryStore(fileURL: historyURL)

        // 1. Append active runs (creates history.jsonl and history.db)
        store.append(mode: "turbo", params: ["streams": 4], raw: #"{"mbps": 120}"#)
        store.append(mode: "baseline", params: ["seconds": 5], raw: #"{"mbps": 50}"#)
        XCTAssertEqual(store.loadAll().count, 2)

        // 2. Clear creates cleared-history.jsonl
        store.clear()
        XCTAssertTrue(store.holdingBinExists())

        // 3. Append another run to restore active history.jsonl and history.db
        store.append(mode: "boost", params: ["streams": 8], raw: #"{"mbps": 200}"#)
        XCTAssertEqual(store.loadAll().count, 1)

        // 4. Create archive-history.jsonl
        let archiveURL = HistoryStore.archiveFileURL(forFileAt: historyURL)
        let archiveLine = #"{"ts":"2026-01-01T00:00:00Z","mode":"old","params":{},"result_raw":"{}"}"# + "\n"
        try archiveLine.write(to: archiveURL, atomically: true, encoding: .utf8)

        // Verify all 4 artifacts exist on disk before erase
        let dbURL = tempDir.appendingPathComponent("history.db")
        let clearedURL = HistoryStore.holdingBinURL(forFileAt: historyURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clearedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))

        // Create dummy wal and shm sidecars
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        try? "wal".write(to: walURL, atomically: true, encoding: .utf8)
        try? "shm".write(to: shmURL, atomically: true, encoding: .utf8)

        // Perform eraseAll
        let status = store.eraseAll()

        // Assert all files reported success
        XCTAssertEqual(status["history.db"], true)
        XCTAssertEqual(status["history.jsonl"], true)
        XCTAssertEqual(status["archive-history.jsonl"], true)
        XCTAssertEqual(status["cleared-history.jsonl"], true)
        XCTAssertTrue(status.values.allSatisfy { $0 })

        // Assert all 4 artifacts and sidecars are absent from disk
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearedURL.path))

        // Assert unrelated sentinel is completely untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "sentinel-contents")

        // Assert store loadAll is empty
        XCTAssertEqual(store.loadAll().count, 0)

        // Assert append works afterward
        store.append(mode: "baseline", params: ["seconds": 10], raw: #"{"mbps": 75}"#)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func testEraseAllOnEmptyStoreSucceedsIdempotently() throws {
        let store = HistoryStore(fileURL: historyURL)
        let status = store.eraseAll()
        XCTAssertEqual(status["history.db"], true)
        XCTAssertEqual(status["history.jsonl"], true)
        XCTAssertEqual(status["archive-history.jsonl"], true)
        XCTAssertEqual(status["cleared-history.jsonl"], true)
        XCTAssertTrue(status.values.allSatisfy { $0 })
    }

    func testEraseAllReportsFailureOnPermissionErrorWithoutFalseSuccess() throws {
        // Create an unwriteable directory to simulate deletion failure
        let lockedDir = tempDir.appendingPathComponent("locked-sub", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let lockedHistoryURL = lockedDir.appendingPathComponent("history.jsonl")
        try "test-line\n".write(to: lockedHistoryURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(fileURL: lockedHistoryURL)

        // Remove write permission from parent directory so removeItem will fail
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDir.path)
        }

        let status = store.eraseAll()
        // history.jsonl deletion must fail and report false
        XCTAssertEqual(status["history.jsonl"], false)
        XCTAssertFalse(status.values.allSatisfy { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedHistoryURL.path))
    }
}
