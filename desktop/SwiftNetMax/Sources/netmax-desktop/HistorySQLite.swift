//
//  HistorySQLite.swift
//  netmax-desktop
//
//  Task 4 — SQLite as the PRIMARY history store (reverses the opt-in F20
//  decision now that the layer is battle-tested). Design:
//
//  • One table `history` mirroring HistoryRecord fields (ts, mode, params,
//    result_raw, network, note) with an INTEGER PRIMARY KEY and indexes on
//    ts + (ts, mode).
//  • JSONL stays as the append-log / Python-compat mirror — every append
//    still lands there (atomic, corrupt-line tolerant), but READS prefer
//    SQLite when it has rows; full rewrites (clear / delete / restore /
//    retention / updateNote) rewrite BOTH so the mirror never drifts.
//  • history.db sits beside history.jsonl in
//    ~/Library/Application Support/NetMaxDesktop/.
//  • Failure policy identical to HistoryStore: never crash — any SQLite
//    error falls back to JSONL-only behavior (nil returns / no-ops).
//
//  Schema is deliberately FLAT (one row per run) unlike engine_store's
//  normalized samples/verdicts — HistoryStore only needs the P2 record
//  shape round-tripped losslessly.
//

import Foundation
import SQLite3

/// Thin SQLite3 wrapper for the flat `history` table. Thread-safe via the
/// same NSLock discipline HistoryStore uses (callers hold their own lock;
/// this class assumes single-threaded access under that lock).
final class HistorySQLite {
    /// Process-wide handle beside the standard history.jsonl.
    static let shared = HistorySQLite(
        dbURL: HistoryStore.defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent("history.db"))

    let dbURL: URL
    private var db: OpaquePointer?
    private var openFailed = false

    init(dbURL: URL) {
        self.dbURL = dbURL
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Open / schema

    /// Open (creating if needed) and apply schema. Idempotent. Returns false
    /// on any failure — callers then fall back to JSONL-only.
    @discardableResult
    func open() -> Bool {
        if db != nil { return true }
        guard !openFailed else { return false }
        let dir = dbURL.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
        } catch {
            openFailed = true
            return false
        }

        var handle: OpaquePointer?
        // SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE = 0x2 | 0x4
        let flags = Int32(0x0000_0002 | 0x0000_0004)
        if sqlite3_open_v2(dbURL.path, &handle, flags, nil) != SQLITE_OK {
            openFailed = true
            if let handle { sqlite3_close(handle) }
            return false
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        let schema = """
        CREATE TABLE IF NOT EXISTS history (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            ts          REAL    NOT NULL,
            mode        TEXT    NOT NULL,
            params_json TEXT    NOT NULL DEFAULT '{}',
            result_raw  TEXT    NOT NULL DEFAULT '',
            network     TEXT,
            note        TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_history_ts_mode
            ON history(ts, mode, params_json, result_raw);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, schema, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            #if DEBUG
            print("[HistorySQLite] schema failed: \(msg)")
            #endif
            sqlite3_close(db)
            db = nil
            openFailed = true
            return false
        }
        // F6: owner-only file (0600), same posture as history.jsonl.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
        return true
    }

    // MARK: CRUD

    /// INSERT one record. Returns false on failure (caller keeps JSONL truth).
    @discardableResult
    func insert(_ record: HistoryRecord) -> Bool {
        guard open() else { return false }
        let sql = """
        INSERT OR IGNORE INTO history
            (ts, mode, params_json, result_raw, network, note)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, record.ts.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, record.mode, -1, SQLITE_TRANSIENT)
        let paramsData = (try? JSONSerialization.data(
            withJSONObject: record.params)) ?? Data("{}".utf8)
        sqlite3_bind_text(stmt, 3, String(data: paramsData, encoding: .utf8), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, record.resultRaw, -1, SQLITE_TRANSIENT)
        if let network = record.network {
            sqlite3_bind_text(stmt, 5, network, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let note = record.note {
            sqlite3_bind_text(stmt, 6, note, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Load every row, oldest-first (ts ASC, id ASC for same-second ties).
    /// Empty array on open/read failure.
    func loadAll() -> [HistoryRecord] {
        guard open() else { return [] }
        let sql = "SELECT ts, mode, params_json, result_raw, network, note "
            + "FROM history ORDER BY ts ASC, id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let mode = columnText(stmt, 1) ?? ""
            let paramsJSON = columnText(stmt, 2) ?? "{}"
            let raw = columnText(stmt, 3) ?? ""
            let network = columnText(stmt, 4)
            let note = columnText(stmt, 5)
            var params: [String: Int] = [:]
            if let data = paramsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj {
                    if let n = v as? Int { params[k] = n }
                    else if let d = v as? Double { params[k] = Int(d) }
                }
            }
            out.append(HistoryRecord(
                ts: ts, mode: mode, params: params, resultRaw: raw,
                network: network, note: note))
        }
        return out
    }

    /// True when the table has at least one row (used to prefer SQLite reads).
    func hasRows() -> Bool {
        guard open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM history LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Atomically replace the entire table contents (used after full
    /// JSONL rewrites: clear / deleteMany / restore / retention).
    /// Rolls back on failure so SQLite never ends up half-synced.
    @discardableResult
    func replaceAll(_ records: [HistoryRecord]) -> Bool {
        guard open() else { return false }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        let ok = exec("DELETE FROM history;") && records.allSatisfy { insert($0) }
        if ok {
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        } else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
        return ok
    }

    /// Seed from JSONL when SQLite is empty (first migration after this
    /// feature ships, or a fresh install that already has a history file).
    /// Idempotent: no-op when SQLite already has rows.
    @discardableResult
    func migrateFromJSONLIfNeeded(_ records: [HistoryRecord]) -> Bool {
        guard !records.isEmpty, !hasRows() else { return hasRows() || records.isEmpty }
        return replaceAll(records)
    }

    // MARK: Plumbing

    private func exec(_ sql: String) -> Bool {
        guard open() else { return false }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            sqlite3_free(errMsg)
            return false
        }
        return true
    }

    private func columnText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}

// SQLITE_TRANSIENT tells SQLite to COPY the bytes (Swift strings can move).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Offline self-checks

#if DEBUG
enum HistorySQLiteTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ cond: Bool) { failures += cond ? 0 : 1 }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax.sqlite.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = HistorySQLite(dbURL: dir.appendingPathComponent("history.db"))
        check(db.open())

        let now = Date()
        let a = HistoryRecord(ts: now.addingTimeInterval(-100), mode: "baseline",
                              params: ["seconds": 5], resultRaw: #"{"mbps": 90}"#,
                              network: "nm1:abc", note: "hello")
        let b = HistoryRecord(ts: now, mode: "turbo",
                              params: ["streams": 4, "seconds": 5],
                              resultRaw: #"{"mbps": 120}"#)
        check(db.insert(a))
        check(db.insert(b))
        // INSERT OR IGNORE on duplicate (ts,mode,params,result_raw).
        check(db.insert(a))

        let loaded = db.loadAll()
        check(loaded.count == 2)
        check(loaded[0].mode == "baseline" && loaded[1].mode == "turbo")
        check(loaded[0].params["seconds"] == 5)
        check(loaded[0].resultRaw.contains("90"))
        check(loaded[0].network == "nm1:abc")
        check(loaded[0].note == "hello")
        check(loaded[1].note == nil)

        // Round-trip via JSONL identity (ts equality within same second).
        check(abs(loaded[1].ts.timeIntervalSince(b.ts)) < 0.001)

        // replaceAll shrinks / grows atomically.
        check(db.replaceAll([b]))
        check(db.loadAll().count == 1)
        check(db.replaceAll([a, b]))
        check(db.loadAll().count == 2)

        // migrateFromJSONLIfNeeded: empty DB + records → seed; seeded → no-op.
        let freshURL = dir.appendingPathComponent("fresh.db")
        let fresh = HistorySQLite(dbURL: freshURL)
        check(fresh.migrateFromJSONLIfNeeded([a, b]))
        check(fresh.loadAll().count == 2)
        check(fresh.migrateFromJSONLIfNeeded([a, b, a])) // already seeded
        check(fresh.loadAll().count == 2)

        check(db.hasRows())
        return failures
    }
}
#endif
