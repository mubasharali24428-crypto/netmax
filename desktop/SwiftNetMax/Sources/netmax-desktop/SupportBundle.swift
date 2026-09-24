//
//  SupportBundle.swift
//  netmax-desktop
//
//  N9 crash/support bundle export. Mirrors netmax_bundle.py's sanitize
//  rules (ALEX-250 wave-2) so a Swift-side zip is safe to attach to a bug
//  report: no full history, no env vars, no absolute home paths, no SSIDs.
//
//  Output: a zip containing manifest.json (pretty-printed) written via the
//  standard save panel. Stdlib / Foundation only — no Python invocation.
//

import AppKit
import Foundation

enum SupportBundle {
    static let maxResults = 10
    static let maxStringChars = 2000

    // Keys dropped entirely — full history, env shapes, Wi-Fi identity.
    static let dropKeys: Set<String> = [
        "history", "runs", "all_results", "full_history",
        "env", "environ", "environment",
        "ssid", "wifi_ssid", "network_name",
    ]
    static let redactValueKeys: Set<String> = ["password", "secret", "token", "api_key"]

    // MARK: Sanitize (mirrors netmax_bundle.sanitize)

    static func scrubString(_ s: String) -> String {
        var out = s
        // /Users/<name> → ~user (any leading-slash shape collapses).
        if let re = try? NSRegularExpression(pattern: #"/+Users/[^/\s\"'`,;:)\]}]+"#) {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "~user")
        }
        // ssid / wifi name / network name: <key>=<redacted>
        if let re = try? NSRegularExpression(
            pattern: #"\b(ssid|wi[-_]?fi[ _-]?name|network[ _-]?name)\s*[:=]\s*\S+"#,
            options: [.caseInsensitive]) {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1=<redacted>")
        }
        return out
    }

    static func truncate(_ s: String) -> String {
        guard s.count > maxStringChars else { return s }
        let extra = s.count - maxStringChars
        return String(s.prefix(maxStringChars)) + " ...[+\(extra) chars truncated]"
    }

    /// Deep-copy `value` with drop/redact/scrub/truncate rules applied.
    static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, val) in dict {
                let k = key.lowercased()
                if dropKeys.contains(k) || k.contains("ssid") { continue }
                if redactValueKeys.contains(k) {
                    out[key] = "<redacted>"
                } else {
                    out[key] = sanitize(val)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { sanitize($0) }
        }
        if let str = value as? String {
            return truncate(scrubString(str))
        }
        return value
    }

    // MARK: Collect

    /// Last N history records as plain dicts (mode + params + truncated raw).
    /// Key is deliberately "entries", never "runs"/"history" (those keys are
    /// dropped unconditionally by sanitize — same note as the Python bundle).
    static func collect(store: HistoryStore = .shared) -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let records = store.loadAll()
        let recent = records.suffix(Self.maxResults)
        let entries: [[String: Any]] = recent.map { r in
            [
                "mode": r.mode,
                "params": r.params,
                // Truncated raw payload — never the full history.
                "result_raw": truncate(scrubString(r.resultRaw)),
                "ts": ISO8601DateFormatter().string(from: r.ts),
            ]
        }
        return [
            "bundle_version": 1,
            "generated_utc": ISO8601DateFormatter().string(from: Date()),
            "app": ["name": "netmax-desktop", "version": version, "build": build],
            "platform": [
                "system": "macOS",
                "machine": runSysctl("hw.machine") ?? "?",
                "os_release": runSysctl("kern.osrelease") ?? "?",
            ],
            "crash_free_uptime_note": uptimeNote(),
            "results_last_n": [
                "max_kept": Self.maxResults,
                "count": entries.count,
                "entries": entries,
            ],
        ]
    }

    private static func runSysctl(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        p.arguments = ["-n", name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            guard let data = out.fileHandleForReading.readDataToEndOfFile() as Data?,
                  let s = String(data: data, encoding: .utf8) else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        } catch {
            return nil
        }
    }

    private static func uptimeNote() -> String {
        // sysctl kern.boottime → "sec=…, usec=…"
        guard let raw = runSysctl("kern.boottime"),
              let range = raw.range(of: #"sec\s*=\s*(\d+)"#, options: .regularExpression) else {
            return "crash-free uptime: unknown (system boot time unavailable)"
        }
        let num = raw[range].filter { $0.isNumber }
        guard let boot = Double(num) else {
            return "crash-free uptime: unknown (system boot time unavailable)"
        }
        let days = max(Date().timeIntervalSince1970 - boot, 0) / 86_400
        return String(
            format: "crash-free uptime: system up %.1f days at bundle time", days)
    }

    // MARK: Write zip

    /// Pretty-printed JSON for nested dicts/arrays.
    static func prettyJSON(_ obj: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
    }

    /// Sanitize + write `manifest.json` into a new zip at `url`.
    /// Returns the final sanitized dict (for tests / previews).
    @discardableResult
    static func writeZip(to url: URL, store: HistoryStore = .shared) throws -> [String: Any] {
        let clean = sanitize(collect(store: store)) as! [String: Any]
        let data = try prettyJSON(clean)

        // Build the zip with a tiny STORED (no compression) entry — enough
        // for a single JSON manifest and avoids pulling in Compression just
        // for one file. Zip local-file-header layout (PK\x03\x04 …).
        let name = "manifest.json"
        let nameBytes = Array(name.utf8)
        let crc = crc32IEEE(data)
        var zip = Data()
        func append<T: FixedWidthInteger>(_ v: T, little: Bool = true) {
            var le = little ? v.littleEndian : v.bigEndian
            withUnsafeBytes(of: &le) { zip.append(contentsOf: $0) }
        }
        // Local file header
        zip.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // PK\3\4
        append(UInt16(20))                               // version needed
        append(UInt16(0))                                // flags
        append(UInt16(0))                                // method: store
        append(UInt16(0))                                // mod time
        append(UInt16(0))                                // mod date
        append(crc)                                      // crc-32
        append(UInt32(data.count))                       // compressed size
        append(UInt32(data.count))                       // uncompressed size
        append(UInt16(nameBytes.count))
        append(UInt16(0))                                // extra len
        zip.append(contentsOf: nameBytes)
        zip.append(data)
        // Central directory
        let cdOffset = UInt32(zip.count)
        zip.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // PK\1\2
        append(UInt16(20))                               // version made by
        append(UInt16(20))                               // version needed
        append(UInt16(0))
        append(UInt16(0))
        append(UInt16(0))
        append(UInt16(0))
        append(crc)
        append(UInt32(data.count))
        append(UInt32(data.count))
        append(UInt16(nameBytes.count))
        append(UInt16(0))
        append(UInt16(0))                                // comment len
        append(UInt16(0))                                // disk start
        append(UInt16(0))                                // int attr
        append(UInt32(0))                                // ext attr
        append(UInt32(0))                                // local header offset (0)
        zip.append(contentsOf: nameBytes)
        // End of central directory
        let cdSize = UInt32(zip.count) - cdOffset
        zip.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // PK\5\6
        append(UInt16(0))
        append(UInt16(0))
        append(UInt16(1))
        append(UInt16(1))
        append(cdSize)
        append(cdOffset)
        append(UInt16(0))
        try zip.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        return clean
    }

    /// IEEE CRC-32 (zip polynomial), table-driven.
    static func crc32IEEE(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Run the save panel and write the zip. Returns the URL on success.
    static func export(store: HistoryStore = .shared) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "netmax-support-bundle.zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try writeZip(to: url, store: store)
            return url
        } catch {
            #if DEBUG
            print("[SupportBundle] write failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}

// MARK: - Offline self-checks (house style)

#if DEBUG
enum SupportBundleTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ cond: Bool) { failures += cond ? 0 : 1 }

        // Sanitize: home paths → ~user, SSID dropped, secrets redacted,
        // long strings truncated, history-like keys dropped.
        let dirty: [String: Any] = [
            "path": "/Users/alice/Library/history.jsonl",
            "ssid": "CoffeeShop",
            "wifi_ssid_2": "Guest",
            "password": "hunter2",
            "token": "abc",
            "env": ["PATH": "/usr/bin"],
            "history": ["should", "drop"],
            "channel": "6",
            "rssi_dbm": -55,
            "note": "moved router",
            "long": String(repeating: "x", count: 3000),
        ]
        let clean = SupportBundle.sanitize(dirty) as! [String: Any]
        check(clean["path"] as? String == "~user/Library/history.jsonl")
        check(clean["ssid"] == nil)
        check(clean["wifi_ssid_2"] == nil)
        check(clean["env"] == nil)
        check(clean["history"] == nil)
        check(clean["password"] as? String == "<redacted>")
        check(clean["token"] as? String == "<redacted>")
        check(clean["channel"] as? String == "6")
        check(clean["rssi_dbm"] as? Int == -55)
        check((clean["long"] as? String)?.count ?? 0 < 3100)
        check((clean["long"] as? String)?.hasSuffix("chars truncated]") == true)

        // History store: last ≤10 records only, never keyed "history".
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax.sb.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        for i in 0..<15 {
            store.append(mode: "baseline", params: ["i": i], raw: #"{"grade":"A"}"#)
        }
        let bundle = SupportBundle.collect(store: store)
        check(bundle["history"] == nil)
        if let lastN = bundle["results_last_n"] as? [String: Any],
           let entries = lastN["entries"] as? [Any] {
            check(entries.count == SupportBundle.maxResults)
        } else {
            failures += 1
        }

        // Zip round-trip: PK magic + manifest.json payload present.
        let zipURL = dir.appendingPathComponent("out.zip")
        do {
            let cleanOut = try SupportBundle.writeZip(to: zipURL, store: store)
            check(cleanOut["results_last_n"] != nil)
            let data = try Data(contentsOf: zipURL)
            check(data.count > 4)
            check(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
            // Locate the stored manifest.json bytes after the local header.
            let name = "manifest.json".data(using: .utf8)!
            if let nameRange = data.range(of: name),
               let jsonStart = data.range(of: Data([0x7B /* { */]),
                                          options: [], in: nameRange.upperBound..<data.endIndex) {
                let json = data[jsonStart.lowerBound...]
                check(String(data: json.prefix(20), encoding: .utf8)?.hasPrefix("{") == true)
            } else {
                failures += 1
            }
        } catch {
            failures += 1
        }

        try? FileManager.default.removeItem(at: dir)
        return failures
    }
}
#endif
