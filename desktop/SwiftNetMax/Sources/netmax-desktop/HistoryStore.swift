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

    /// Delete the entire history file. The next append recreates it.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            // Nothing to clear — already clean.
        } catch {
            #if DEBUG
            print("[HistoryStore] clear failed: \(error.localizedDescription)")
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
