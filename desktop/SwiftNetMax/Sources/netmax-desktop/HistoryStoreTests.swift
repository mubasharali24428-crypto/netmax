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

        return failures
    }

    private static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-history-tests-\(UUID().uuidString).jsonl")
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
