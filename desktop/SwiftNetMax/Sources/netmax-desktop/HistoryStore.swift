import Foundation

/// One persisted measurement run (contract P2).
///
/// Serialized as a single JSON line in
/// `~/Library/Application Support/NetMaxDesktop/history.jsonl` with exactly
/// these keys: `{"ts": <ISO8601>, "mode": str, "params": {str: int}, "result_raw": str}`.
/// Swift-side names stay idiomatic (`resultRaw`) while the wire format keeps
/// the contract's snake_case via explicit `CodingKeys`.
struct HistoryRecord: Codable, Equatable {
    let ts: Date
    let mode: String
    let params: [String: Int]
    let resultRaw: String

    enum CodingKeys: String, CodingKey {
        case ts, mode, params
        case resultRaw = "result_raw"
    }

    init(ts: Date, mode: String, params: [String: Int], resultRaw: String) {
        self.ts = ts
        self.mode = mode
        self.params = params
        self.resultRaw = resultRaw
    }

    /// Decode tolerant copy used when reading possibly-stale lines.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Date.self, forKey: .ts)
        mode = try c.decode(String.self, forKey: .mode)
        params = try c.decode([String: Int].self, forKey: .params)
        resultRaw = try c.decode(String.self, forKey: .resultRaw)
    }
}

/// Local measurement history store (contract P2).
///
/// Storage is append-only JSON Lines at
/// `~/Library/Application Support/NetMaxDesktop/history.jsonl`:
/// one `HistoryRecord` per line, oldest-first on disk. All access is
/// guarded by an `NSLock`, so the store is safe to call from any thread
/// (engine completion handlers, UI, menu bar popover simultaneously).
///
/// Failure policy: history must never take the app down. Unreadable/corrupt
/// lines are skipped silently on load; write errors are swallowed (logged in
/// DEBUG builds only). The storage directory is created lazily on first write.
final class HistoryStore {

    /// Process-wide store pointed at the standard Application Support path.
    static let shared = HistoryStore()

    /// Contract P2 location: ~/Library/Application Support/NetMaxDesktop/history.jsonl
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("NetMaxDesktop", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    private let fileURL: URL
    private let lock = NSLock()

    /// ISO8601 timestamps, e.g. `2026-08-23T12:34:56Z` (contract P2).
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// - Parameter fileURL: overrides the storage path (tests / self-checks);
    ///   production callers use `shared`, which uses `defaultFileURL`.
    init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    // MARK: - API

    /// Append one completed run to the history file.
    ///
    /// Creates the containing directory and file on first write. Thread-safe.
    /// - Parameters:
    ///   - mode: engine mode name (e.g. "baseline", "turbo").
    ///   - params: run parameters as passed to the engine (e.g. ["streams": 8]).
    ///   - raw: the engine's raw result payload (pretty-printed JSON text).
    func append(mode: String, params: [String: Int], raw: String) {
        let record = HistoryRecord(ts: Date(), mode: mode, params: params, resultRaw: raw)
        lock.lock()
        defer { lock.unlock() }
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            var line = try encoder.encode(record)
            line.append(0x0A) // JSON Lines: newline-terminated
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // History is best-effort; a failed append must never crash the app.
            #if DEBUG
            print("[HistoryStore] append failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Load every readable record, oldest-first (file order).
    ///
    /// Missing file → empty array. Corrupt/partial lines are skipped silently,
    /// so a truncated last line (crash mid-write) costs nothing.
    func loadAll() -> [HistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Self.readRecords(from: fileURL, decoder: decoder)
    }

    /// W12 T1-a (W11-A-093): Clear is soft-delete — the whole file MOVES to
    /// `cleared-history.jsonl` beside it (same dir) instead of being deleted,
    /// so "Undo"/"Restore Last Clear" can bring it back. A second clear
    /// replaces the holding bin: it holds the LAST cleared batch (Trash-style).
    /// The next append recreates the (now missing) history file.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return // Nothing to clear — already clean.
            }
            let binURL = Self.holdingBinURL(forFileAt: fileURL)
            if FileManager.default.fileExists(atPath: binURL.path) {
                try FileManager.default.removeItem(at: binURL) // last-clear wins
            }
            try FileManager.default.moveItem(at: fileURL, to: binURL)
        } catch {
            #if DEBUG
            print("[HistoryStore] clear failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: Holding bin (W12 T1-a)

    /// Location of the clear-holding bin: `cleared-history.jsonl` in the same
    /// directory as `history.jsonl`.
    static func holdingBinURL(forFileAt url: URL = HistoryStore.defaultFileURL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("cleared-history.jsonl")
    }

    /// True while a cleared batch sits in the holding bin (drives the
    /// "Restore Last Clear" toolbar item and the post-Clear undo affordance).
    func holdingBinExists() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.binHasContent(forFileAt: fileURL)
    }

    /// Move the holding bin back into history (W12 T1-a).
    ///
    /// Held records MERGE into any newer ones appended since the clear;
    /// duplicates are detected by ts+mode identity (same pair the store
    /// round-trips losslessly) so restoring twice cannot double-insert.
    /// The bin is consumed either way. Returns true when held records were
    /// restored (or were already all present); false when there was nothing
    /// restorable (no bin, or no readable records in it).
    ///
    /// Static per the lane contract; the work runs on `shared`, under the
    /// store's lock, against the shared store's file.
    @discardableResult
    static func restoreLastClear() -> Bool {
        HistoryStore.shared.restoreHoldingBin()
    }

    private func restoreHoldingBin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let binURL = Self.holdingBinURL(forFileAt: fileURL)
        guard FileManager.default.fileExists(atPath: binURL.path) else { return false }

        let held = Self.readRecords(from: binURL, decoder: decoder)
        try? FileManager.default.removeItem(at: binURL) // consumed regardless
        guard !held.isEmpty else { return false }

        var current = Self.readRecords(from: fileURL, decoder: decoder)
        let keys = Set(current.map(Self.identityKey))
        for record in held where !keys.contains(Self.identityKey(record)) {
            current.append(record)
        }
        // Keep the documented on-disk invariant: oldest-first, atomic swap.
        current.sort { $0.ts < $1.ts }
        do {
            if current.isEmpty {
                // Unreachable in practice (held non-empty ⇒ current non-empty);
                // kept symmetric with delete(_:) so the invariant can't drift.
                try FileManager.default.removeItem(at: fileURL)
            } else {
                var blob = Data()
                for record in current {
                    blob.append(try encoder.encode(record))
                    blob.append(0x0A) // JSON Lines: newline-terminated
                }
                try blob.write(to: fileURL, options: .atomic)
            }
            return true
        } catch {
            #if DEBUG
            print("[HistoryStore] restore failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Merge/dedupe identity: ts + mode (P2 fields the store round-trips
    /// losslessly; two runs in the same mode share a ts only on collision).
    private static func identityKey(_ record: HistoryRecord) -> String {
        "\(record.ts.timeIntervalSince1970)|\(record.mode)"
    }

    /// Bin counts as existing only when it holds at least one readable record
    /// (an emptied/corrupt bin offers nothing to restore).
    private static func binHasContent(forFileAt url: URL) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return !readRecords(from: holdingBinURL(forFileAt: url), decoder: decoder).isEmpty
    }

    /// Deletes ONE run: the first stored record equal to `record`.
    ///
    /// W12 T4-b (audit 154): backs HistoryView's right-click "Delete This Run".
    /// Rewrites the file atomically, preserving oldest-first order; a missing
    /// match is a no-op; deleting the last record removes the file entirely
    /// (the next append recreates it, same policy as `clear()`). Thread-safe.
    func delete(_ record: HistoryRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = Self.readRecords(from: fileURL, decoder: decoder)
        guard let index = records.firstIndex(of: record) else { return }
        records.remove(at: index)
        do {
            if records.isEmpty {
                try FileManager.default.removeItem(at: fileURL)
                return
            }
            var blob = Data()
            for line in records {
                blob.append(try encoder.encode(line))
                blob.append(0x0A) // JSON Lines: newline-terminated
            }
            try blob.write(to: fileURL, options: .atomic)
        } catch {
            // Same best-effort policy as append/clear: never crash the app.
            #if DEBUG
            print("[HistoryStore] delete failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Internals

    private static func readRecords(from url: URL, decoder: JSONDecoder) -> [HistoryRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var records: [HistoryRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let record = try? decoder.decode(HistoryRecord.self, from: data)
            else { continue } // corrupt line: skip silently (P2)
            records.append(record)
        }
        return records
    }
}
