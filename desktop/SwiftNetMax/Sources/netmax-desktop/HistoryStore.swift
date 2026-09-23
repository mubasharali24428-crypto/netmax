import CryptoKit
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

    /// W13B UA-2 (S-098): network name (SSID) the run was measured on, when
    /// it could be determined; `nil` otherwise. Optional + decoded with
    /// `decodeIfPresent`, so pre-W13B records (no `network` key) load as-is.
    let network: String?

    /// W13B UA-3 (S-028): user annotation ("moved router"). Same backward-
    /// compatibility contract as `network`.
    var note: String?

    enum CodingKeys: String, CodingKey {
        case ts, mode, params
        case resultRaw = "result_raw"
        case network, note
    }

    init(ts: Date, mode: String, params: [String: Int], resultRaw: String,
         network: String? = nil, note: String? = nil) {
        self.ts = ts
        self.mode = mode
        self.params = params
        self.resultRaw = resultRaw
        self.network = network
        self.note = note
    }

    /// Decode tolerant copy used when reading possibly-stale lines.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Date.self, forKey: .ts)
        mode = try c.decode(String.self, forKey: .mode)
        params = try c.decode([String: Int].self, forKey: .params)
        resultRaw = try c.decode(String.self, forKey: .resultRaw)
        network = try c.decodeIfPresent(String.self, forKey: .network)
        note = try c.decodeIfPresent(String.self, forKey: .note)
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

    // MARK: F7 — SSID minimization at rest

    /// Per-install random salt, shared file with the Python engine
    /// (`privacy.salt` beside the history file) so both lanes hash SSIDs
    /// identically. 0600, created on first use.
    private static func privacySalt() -> Data {
        let url = defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent("privacy.salt")
        if let existing = try? Data(contentsOf: url), existing.count >= 16 {
            return existing.prefix(32)
        }
        var fresh = Data(count: 32)
        let status = fresh.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard status == errSecSuccess else { return Data(repeating: 0x2A, count: 32) }
        try? fresh.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return fresh
    }

    /// Salted SHA-256, `nm1:`-prefixed — byte-identical to the Python
    /// engine's `hash_identifier` (netmax_wifievents.py) so a Swift-tagged
    /// run and a Python-tagged run compare equal.
    static func hashNetworkTag(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        var data = privacySalt()
        data.append(0x00)
        data.append(Data(name.utf8))
        let digest = SHA256.hash(data: data)
        return "nm1:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - API

    /// F6 FIX (security audit): measurement history + SSID are personal
    /// data; the files that hold them are created owner-only (0600) and the
    /// containing dir 0700, mirroring the Python eventstore (0o600).
    static func applyPrivacyPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: url.path)
    }

    private static func ensurePrivateContainer(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// Append one completed run to the history file.
    ///
    /// Creates the containing directory and file on first write. Thread-safe.
    /// Returns the record that was written so callers can hand it straight
    /// to `RunPostProcessor.process(_:)` (call AFTER append contract).
    /// - Parameters:
    ///   - mode: engine mode name (e.g. "baseline", "turbo").
    ///   - params: run parameters as passed to the engine (e.g. ["streams": 8]).
    ///   - raw: the engine's raw result payload (pretty-printed JSON text).
    ///   - network: network name (SSID) for W13B UA-2 network-scoped baselines;
    ///     pass `nil` when it can't be determined (old callers stay valid).
    /// F7: the stored `network` value is the hash, never the raw SSID —
    /// equality comparisons (baseline scoping, change banner) are
    /// unaffected; the raw name stops persisting in history.
    @discardableResult
    func append(mode: String, params: [String: Int], raw: String, network: String? = nil) -> HistoryRecord {
        let storedNetwork = Self.hashNetworkTag(network)
        let record = HistoryRecord(ts: Date(), mode: mode, params: params,
                                   resultRaw: raw, network: storedNetwork)
        lock.lock()
        defer { lock.unlock() }
        do {
            try Self.ensurePrivateContainer(for: fileURL)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600])
            } else {
                Self.applyPrivacyPermissions(fileURL) // tighten pre-existing files too
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
        return record
    }

    /// Load every readable record, oldest-first (file order).
    ///
    /// Missing file → empty array. Corrupt/partial lines are skipped silently,
    /// so a truncated last line (crash mid-write) costs nothing.
    ///
    /// W13B TEAM-UB / UB-4: this is also where the "Keep history for N days"
    /// setting is ENFORCED — expired records move to `archive-history.jsonl`
    /// before being excluded from the result. `0` (the default) keeps
    /// everything forever and never touches the files.
    func loadAll() -> [HistoryRecord] {
        let retentionDays = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
        lock.lock()
        defer { lock.unlock() }
        guard retentionDays > 0 else {
            return Self.readRecords(from: fileURL, decoder: decoder)
        }
        return enforceRetentionLocked(days: retentionDays)
    }

    /// Retention pass with the lock already held (`loadAll`'s fast path takes
    /// it once; `enforceRetention(days:)` is the public testable wrapper that
    /// takes it itself). See `enforceRetention` for the full contract.
    private func enforceRetentionLocked(days retentionDays: Int,
                                        now: Date = Date()) -> [HistoryRecord] {
        let all = Self.readRecords(from: fileURL, decoder: decoder)
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let expired = all.filter { $0.ts < cutoff }
        guard !expired.isEmpty else { return all }

        // 1) Append the expired batch to the archive file. Best-effort: a
        //    failed archive write aborts the prune so nothing is lost.
        do {
            let archiveURL = Self.archiveFileURL(forFileAt: fileURL)
            try Self.ensurePrivateContainer(for: archiveURL)
            var archiveBlob = Data()
            for record in expired {
                archiveBlob.append(try encoder.encode(record))
                archiveBlob.append(0x0A)
            }
            let handle: FileHandle
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                handle = try FileHandle(forWritingTo: archiveURL)
            } else {
                FileManager.default.createFile(atPath: archiveURL.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600])
                handle = try FileHandle(forWritingTo: archiveURL)
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: archiveBlob)
        } catch {
            #if DEBUG
            print("[HistoryStore] retention archive failed: \(error.localizedDescription)")
            #endif
            return all // nothing pruned when archiving fails
        }

        // 2) Rewrite the live file with just the survivors.
        let kept = all.filter { $0.ts >= cutoff }
        do {
            if kept.isEmpty {
                try FileManager.default.removeItem(at: fileURL)
            } else {
                var blob = Data()
                for record in kept {
                    blob.append(try encoder.encode(record))
                    blob.append(0x0A)
                }
                try blob.write(to: fileURL, options: .atomic)
                Self.applyPrivacyPermissions(fileURL) // F6: .atomic resets perms
            }
        } catch {
            #if DEBUG
            print("[HistoryStore] retention rewrite failed: \(error.localizedDescription)")
            #endif
            return all // live file untouched; archive holds a safe duplicate
        }
        return kept
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
            Self.applyPrivacyPermissions(binURL) // F6: bin holds the same personal data
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

    /// Instance-level merge used by `restoreLastClear()` (which pins the work
    /// to `shared`). Internal rather than private so offline /tmp probes can
    /// exercise the identical merge/dedupe path against an isolated store;
    /// production callers should always go through the static form.
    func restoreHoldingBin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let binURL = Self.holdingBinURL(forFileAt: fileURL)
        guard FileManager.default.fileExists(atPath: binURL.path) else { return false }

        let held = Self.readRecords(from: binURL, decoder: decoder)
        try? FileManager.default.removeItem(at: binURL) // consumed regardless
        guard !held.isEmpty else { return false }

        var current = Self.readRecords(from: fileURL, decoder: decoder)
        let keys = Set(current.map(Self.identityKey))
        let fresh = held.filter { !keys.contains(Self.identityKey($0)) }

        // Stable merge (W12 T1-a): both sides are oldest-first. NOTE the P2
        // wire format stores whole seconds (ISO8601), so same-second records
        // tie — a plain sort would be free to reorder them. The two-pointer
        // merge below keeps existing file order ahead of restored records
        // whenever timestamps tie, preserving the append-only chronology.
        var merged: [HistoryRecord] = []
        merged.reserveCapacity(current.count + fresh.count)
        var i = 0, j = 0
        while i < current.count && j < fresh.count {
            if fresh[j].ts < current[i].ts {
                merged.append(fresh[j]); j += 1
            } else {
                merged.append(current[i]); i += 1 // ties favor existing file order
            }
        }
        merged.append(contentsOf: current[i...])
        merged.append(contentsOf: fresh[j...])
        current = merged
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
                Self.applyPrivacyPermissions(fileURL) // F6: .atomic resets perms
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
        deleteMany([record])
    }

    /// W13B TEAM-UB / UB-4 (S-034/S-035): bulk delete behind HistoryView's
    /// multi-select mode. One atomic rewrite (never N passes); records are
    /// matched by the store's lossless ts+mode identity, so a caller's stale
    /// copies still match. Returns the number of records actually removed.
    @discardableResult
    func deleteMany(_ records: [HistoryRecord]) -> Int {
        guard !records.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let doomed = Set(records.map(Self.identityKey))
        let kept = Self.readRecords(from: fileURL, decoder: decoder)
            .filter { !doomed.contains(Self.identityKey($0)) }
        let removed = Self.readRecords(from: fileURL, decoder: decoder).count - kept.count
        guard removed > 0 else { return 0 }
        do {
            if kept.isEmpty {
                try FileManager.default.removeItem(at: fileURL)
            } else {
                var blob = Data()
                for line in kept {
                    blob.append(try encoder.encode(line))
                    blob.append(0x0A) // JSON Lines: newline-terminated
                }
                try blob.write(to: fileURL, options: .atomic)
                Self.applyPrivacyPermissions(fileURL) // F6: .atomic resets perms
            }
        } catch {
            // Same best-effort policy as append/clear: never crash the app.
            #if DEBUG
            print("[HistoryStore] bulk delete failed: \(error.localizedDescription)")
            #endif
        }
        return removed
    }

    // MARK: Retention & archive (W13B TEAM-UB / UB-4)

    /// Settings key backing "Keep history for N days" (0 = keep forever).
    static let retentionDaysKey = "netmax.history.retentionDays"

    /// Archive location: records pruned by retention move here instead of
    /// being destroyed (`archive-history.jsonl` beside the live history).
    static func archiveFileURL(forFileAt url: URL = HistoryStore.defaultFileURL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("archive-history.jsonl")
    }

    /// Enforce the retention window: records older than `retentionDays` are
    /// MOVED to `archive-history.jsonl` (append — never silently destroyed)
    /// and excluded from the returned array. `retentionDays <= 0` keeps
    /// everything forever and never touches disk. Public testable wrapper —
    /// takes the lock itself; production loads reach this via `loadAll()`.
    /// - Returns: records kept (file/oldest-first order preserved).
    func enforceRetention(days retentionDays: Int,
                          now: Date = Date()) -> [HistoryRecord] {
        guard retentionDays > 0 else { return Self.readRecords(from: fileURL, decoder: decoder) }
        lock.lock()
        defer { lock.unlock() }
        return enforceRetentionLocked(days: retentionDays, now: now)
    }

    // MARK: - Internals

    /// W13B UA-3 (S-028): set or clear a run's user annotation, matched by
    /// the same ts+mode identity the store round-trips losslessly. Rewrites
    /// the file atomically; no match is a no-op; empty/whitespace-only text
    /// clears. Returns true when the file was updated. Thread-safe.
    @discardableResult
    func updateNote(_ note: String?, for record: HistoryRecord) -> Bool {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (trimmed?.isEmpty == true) ? nil : trimmed
        lock.lock()
        defer { lock.unlock() }
        var records = Self.readRecords(from: fileURL, decoder: decoder)
        guard let index = records.firstIndex(where: {
            $0.ts == record.ts && $0.mode == record.mode
        }) else { return false }
        records[index].note = cleaned
        do {
            var blob = Data()
            for line in records {
                blob.append(try encoder.encode(line))
                blob.append(0x0A) // JSON Lines: newline-terminated
            }
            try blob.write(to: fileURL, options: .atomic)
            Self.applyPrivacyPermissions(fileURL) // F6: .atomic resets perms
            return true
        } catch {
            #if DEBUG
            print("[HistoryStore] updateNote failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

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
