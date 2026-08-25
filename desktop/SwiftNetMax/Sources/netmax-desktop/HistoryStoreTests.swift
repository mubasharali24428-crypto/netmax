import Foundation

// Offline unit tests for HistoryStore (contract P2).
//
// Package.swift has no test target (single executable target), and lane rules
// forbid editing shared build files, so this file intentionally does NOT
// compile as XCTest. It is compiled into the DEBUG build as a plain enum with
// static checks; the real offline verification runs via a temp-dir script
// harness against the same API (see mission report). If a test target is ever
// added, these bodies convert 1:1 into XCTestCase methods.

enum HistoryStoreTests {
    /// Run all checks; returns number of failures (0 == pass).
    @discardableResult
    static func runAll() -> Int {
        var failures = 0

        // Round-trip: append ×2 → load → count == 2, ordering + payload intact.
        do {
            let url = tempFile()
            let store = HistoryStore(fileURL: url)
            defer { cleanup(url) }
            precondition(store.loadAll().isEmpty)
            store.append(mode: "baseline", params: ["streams": 8], raw: "{\"throughput\": 940.5}")
            store.append(mode: "turbo", params: ["streams": 4, "seconds": 5], raw: "{\"ok\": true}")
            let all = store.loadAll()
            assert(all.count == 2)
            failures += (all.count == 2) ? 0 : 1
            failures += (all[0].mode == "baseline") ? 0 : 1
            failures += (all[0].params["streams"] == 8) ? 0 : 1
            failures += (all[0].resultRaw.contains("940.5")) ? 0 : 1
            failures += (all[1].params["seconds"] == 5) ? 0 : 1
            // ISO8601 wire format per contract P2.
            let line = try! String(contentsOf: url, encoding: .utf8)
            failures += (line.contains("\"result_raw\"")) ? 0 : 1
            let isoMatch = line.range(
                of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#,
                options: String.CompareOptions.regularExpression)
            failures += (isoMatch != nil) ? 0 : 1
        }

        // Corrupt lines skipped silently.
        do {
            let url = tempFile()
            let junk = "not json at all\n{\"ts\":\"nope\",\"mode\":\"x\"}\n"
            try! junk.write(to: url, atomically: true, encoding: .utf8)
            let store = HistoryStore(fileURL: url)
            failures += (store.loadAll().isEmpty) ? 0 : 1
            cleanup(url)
        }

        // Missing file behaves as empty; clear() on missing file is a no-op.
        do {
            let url = tempFile()
            let store = HistoryStore(fileURL: url)
            failures += (store.loadAll().isEmpty) ? 0 : 1
            store.clear()
            failures += (store.loadAll().isEmpty) ? 0 : 1
            cleanup(url)
        }

        // MARK: W13B TEAM-UB / UB-4 — bulk delete + retention archive
        //
        // NOTE: append() stamps its own Date(), so these blocks seed the
        // JSONL file directly (P2 wire format) to control timestamps.

        // Bulk delete removes exactly the checked runs in one pass.
        // Whole-second base: the P2 ISO8601 wire format truncates sub-second
        // precision, so identity keys must be computed on stored values.
        do {
            let url = tempFile()
            let archiveURL = HistoryStore.archiveFileURL(forFileAt: url)
            try? FileManager.default.removeItem(at: archiveURL)
            defer { cleanup(url); cleanup(archiveURL) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let records = (0..<5).map { i in
                HistoryRecord(ts: now.addingTimeInterval(Double(-i) * 3600),
                              mode: "baseline", params: [:], resultRaw: "run-\(i)")
            }
            try! Self.writeRecords(records, to: url)
            let store = HistoryStore(fileURL: url)
            // Delete two stale copies (identity is ts+mode, payload ignored).
            let removed = store.deleteMany([records[1], records[3]])
            let survivors = store.loadAll()
            failures += (removed == 2 && survivors.count == 3) ? 0 : 1
            failures += (survivors.contains { $0.ts == records[1].ts }) ? 1 : 0
            // Deleting everything leaves no live file; next append recreates.
            _ = store.deleteMany(survivors)
            failures += (store.loadAll().isEmpty) ? 0 : 1
        }

        // Retention: expired records move to the archive, never vanish.
        // Whole-second base (see note above) for stable ts comparisons.
        do {
            let url = tempFile()
            let archiveURL = HistoryStore.archiveFileURL(forFileAt: url)
            try? FileManager.default.removeItem(at: archiveURL)
            defer { cleanup(url); cleanup(archiveURL) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            // Two old runs (beyond 7 days), one recent.
            let oldA = HistoryRecord(ts: now.addingTimeInterval(-30 * 86_400),
                                     mode: "baseline", params: [:], resultRaw: "old-a")
            let oldB = HistoryRecord(ts: now.addingTimeInterval(-10 * 86_400),
                                     mode: "baseline", params: [:], resultRaw: "old-b")
            let fresh = HistoryRecord(ts: now.addingTimeInterval(-3600),
                                      mode: "baseline", params: [:], resultRaw: "fresh")
            try! Self.writeRecords([oldA, oldB, fresh], to: url)
            let store = HistoryStore(fileURL: url)
            let kept = store.enforceRetention(days: 7, now: now)
            failures += (kept.count == 1 && kept.first?.resultRaw == "fresh") ? 0 : 1

            // The archive holds BOTH pruned records, readable, same order.
            let archived = Self.readArchived(from: archiveURL)
            failures += (archived.count == 2) ? 0 : 1
            failures += (archived.map { $0.resultRaw } == ["old-a", "old-b"])
                ? 0 : 1

            // A retention pass with nothing expired must not touch disk.
            let keptAgain = store.enforceRetention(days: 7, now: now)
            failures += (keptAgain.count == 1) ? 0 : 1
            failures += (Self.readArchived(from: archiveURL).count == 2) ? 0 : 1
        }

        // Retention 0 (forever) keeps everything and creates no archive.
        do {
            let url = tempFile()
            let archiveURL = HistoryStore.archiveFileURL(forFileAt: url)
            try? FileManager.default.removeItem(at: archiveURL)
            defer { cleanup(url); cleanup(archiveURL) }
            let store = HistoryStore(fileURL: url)
            store.append(mode: "baseline", params: [:], raw: "x")
            let kept = store.enforceRetention(days: 0,
                                              now: Date(timeIntervalSince1970: 4_000_000_000))
            failures += (kept.count == 1) ? 0 : 1
            failures += (FileManager.default.fileExists(atPath: archiveURL.path))
                ? 1 : 0
        }

        return failures
    }

    /// Seed a history JSONL file with exact timestamps (P2 wire format,
    /// ISO8601 dates) — append() always stamps Date(), so direct writes are
    /// the only way tests control record ages.
    private static func writeRecords(_ records: [HistoryRecord],
                                     to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var blob = Data()
        for record in records {
            blob.append(try encoder.encode(record))
            blob.append(0x0A)
        }
        try blob.write(to: url, options: .atomic)
    }

    /// Read back a JSONL archive file (same tolerant decoding as the store).
    private static func readArchived(from url: URL) -> [(resultRaw: String, ts: Date)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let record = try? decoder.decode(HistoryRecord.self, from: data)
            else { return nil }
            return (record.resultRaw, record.ts)
        }
    }

    private static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-history-tests-\(UUID().uuidString).jsonl")
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
