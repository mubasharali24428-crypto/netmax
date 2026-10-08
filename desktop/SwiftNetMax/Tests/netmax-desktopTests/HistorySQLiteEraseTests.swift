import XCTest
@testable import netmax_desktop

final class HistorySQLiteEraseTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var sentinelURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-sqlite-erase-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("history.db")
        sentinelURL = tempDir.appendingPathComponent("unrelated_sentinel.txt")
        try! "sentinel-data".write(to: sentinelURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEraseClosesHandleAndRemovesDbAndSidecars() throws {
        let store = HistorySQLite(dbURL: dbURL)
        XCTAssertTrue(store.open())

        let record = HistoryRecord(
            ts: Date(),
            mode: "boost",
            params: ["streams": 8, "seconds": 10],
            resultRaw: #"{"mbps": 150.0}"#
        )
        XCTAssertTrue(store.insert(record))
        XCTAssertTrue(store.hasRows())

        // Create dummy WAL and SHM sidecars if not auto-created
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        try? "wal-data".write(to: walURL, atomically: true, encoding: .utf8)
        try? "shm-data".write(to: shmURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        // Perform erase
        try store.erase()

        // Assert DB and sidecars are completely removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))

        // Assert unrelated sentinel file is untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "sentinel-data")

        // Assert store can be reopened and fresh record inserted cleanly
        let newStore = HistorySQLite(dbURL: dbURL)
        XCTAssertTrue(newStore.open())
        XCTAssertFalse(newStore.hasRows())

        let secondRecord = HistoryRecord(
            ts: Date(),
            mode: "baseline",
            params: ["seconds": 5],
            resultRaw: #"{"mbps": 50.0}"#
        )
        XCTAssertTrue(newStore.insert(secondRecord))
        XCTAssertTrue(newStore.hasRows())
        XCTAssertEqual(newStore.loadAll().count, 1)
    }

    func testEraseOnNonExistentDbSucceedsIdempotently() throws {
        let store = HistorySQLite(dbURL: dbURL)
        XCTAssertNoThrow(try store.erase())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
    }
}
