//
//  ReportExport.swift
//  netmax-desktop
//
//  L3-D — Report export: turn the LAST RESULT shown (one contract-P2
//  history-record's worth of data) into CSV or JSON text, and save it via
//  NSSavePanel.
//
//  Format conventions follow repo-root `netmax_export.py` (M2/E1) where
//  sensible: `timestamp` leads every row, DNS measurements fan out to one
//  row per resolver with the scalar fields repeated, and the DNS columns
//  keep the engine's exact names (`dns_resolver`, `dns_ms`). This UI-side
//  export additionally carries the run identity (`mode` + params), which
//  the CLI exporter picks up from results.json context instead.
//
//  `format(_:as:)` is PURE (Foundation only, no AppKit) so it is
//  unit-testable offline; only `save(_:as:)` touches AppKit.
//

import Foundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Model

/// The result snapshot being exported.
///
/// Plain data with no AppKit dependency, mirroring contract P2's record
/// shape (`ts`/`mode`/`params`/`result_raw`). Deliberately does NOT
/// reference `HistoryRecord` directly — mapping from the store happens in
/// `ReportsView` — so this file compiles and tests stand-alone.
struct ExportRecord {
    let ts: Date
    let mode: String
    let params: [String: Int]
    let raw: String

    init(ts: Date = Date(), mode: String, params: [String: Int], raw: String) {
        self.ts = ts
        self.mode = mode
        self.params = params
        self.raw = raw
    }
}

/// Output formats offered by the Reports tab.
enum ExportFormat: String, CaseIterable {
    case csv
    case json

    /// Filename extension (equals the raw value).
    var fileExtension: String { rawValue }

    /// Human-readable name used in dialogs and status lines.
    var displayName: String {
        switch self {
        case .csv: "CSV (comma-separated)"
        case .json: "JSON"
        }
    }

#if canImport(AppKit)
    /// Save-panel content type restriction per format.
    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        }
    }
#endif
}

// MARK: - Errors

/// User-presentable export failures. Panel dismissal is modeled as an error
/// because the throwing signature returns a non-optional URL on success.
enum ExportError: LocalizedError {
    case cancelled
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: "Export canceled."
        case .encodingFailed: "Could not encode the report."
        }
    }
}

// MARK: - Exporter

enum ReportExporter {

    // MARK: Formatting (pure — no AppKit)

    /// Render one record as the requested format. Deterministic: parameter
    /// and field ordering is sorted, so equal records produce equal bytes.
    static func format(_ r: ExportRecord, as f: ExportFormat) -> String {
        switch f {
        case .csv: csvText(for: r)
        case .json: jsonText(for: r)
        }
    }

    // MARK: CSV

    /// CSV layout (engine-consistent, cf. netmax_export.py):
    ///
    ///     timestamp,mode,<sorted params>,<sorted raw scalars>[,dns_resolver,dns_ms]
    ///
    /// One row per DNS resolver when the raw payload carries a `dns` field
    /// (scalar cells repeated — same convention as the CLI exporter);
    /// otherwise a single row. Trailing newline included.
    private static func csvText(for r: ExportRecord) -> String {
        let paramKeys = r.params.keys.sorted()
        let tsCell = csvField(iso8601(r.ts))
        let modeCell = csvField(r.mode)
        let paramCells = paramKeys.map { csvField(String(r.params[$0] ?? 0)) }

        // Non-JSON payload: nothing to fan out into columns — preserve the
        // engine's text verbatim in one trailing `result_raw` cell instead
        // of silently dropping it.
        guard parsedJSONObject(r.raw) != nil else {
            let header = (["timestamp", "mode"] + paramKeys + ["result_raw"])
                .map(csvField).joined(separator: ",")
            let row = ([tsCell, modeCell] + paramCells + [csvField(r.raw)])
                .joined(separator: ",")
            return "\(header)\n\(row)\n"
        }

        let scalars = scalarFields(in: r.raw, excluding: Set(paramKeys)) // sorted-key dictionary
        let scalarKeys = scalars.keys.sorted()
        let dns = dnsRows(in: r.raw)                   // [[resolver, ms]]

        var header = ["timestamp", "mode"] + paramKeys + scalarKeys
        if !dns.isEmpty { header += ["dns_resolver", "dns_ms"] }
        var lines = [header.map(csvField).joined(separator: ",")]

        let scalarCells = scalarKeys.map { csvField(scalars[$0] ?? "") }

        if dns.isEmpty {
            lines.append(([tsCell, modeCell] + paramCells + scalarCells)
                .joined(separator: ","))
        } else {
            for row in dns {
                let resolver = csvField(row[0])
                let ms = csvField(row[1])
                lines.append(([tsCell, modeCell] + paramCells + scalarCells
                    + [resolver, ms]).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Minimal RFC-4180 quoting: wrap when the value contains comma, quote,
    /// or newline; double embedded quotes.
    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// Top-level scalar fields of the raw payload, keyed by field name.
    /// Nested containers are skipped here (`dns` gets dedicated handling),
    /// and keys already covered by the run parameters are dropped so column
    /// names stay unique (params win — they are the authoritative inputs).
    private static func scalarFields(in raw: String, excluding paramKeys: Set<String>) -> [String: String] {
        guard let obj = parsedJSONObject(raw) else { return [:] }
        var out: [String: String] = [:]
        for key in obj.keys.sorted() where key != "dns" && !paramKeys.contains(key) {
            if let text = describeIfScalar(obj[key]) { out[key] = text }
        }
        return out
    }

    /// Extract `[resolver, ms]` pairs from the raw payload's `dns` field,
    /// tolerating the shapes the engine emits:
    /// `[["1.1.1.1", 12.3], …]`, `[{"resolver"/"name": …, "ms": …}, …]`,
    /// or a plain `{"resolver": ms}` dictionary (rows sorted by resolver).
    private static func dnsRows(in raw: String) -> [[String]] {
        guard let obj = parsedJSONObject(raw), let dns = obj["dns"] else { return [] }

        if let pairs = dns as? [[Any]] {
            return pairs.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return [describe(pair[0]), describe(pair[1])]
            }
        }
        if let entries = dns as? [[String: Any]] {
            return entries.map { entry in
                let name = entry["resolver"] ?? entry["name"] ?? ""
                let ms = entry["ms"] ?? entry["dns_ms"] ?? ""
                return [describe(name), describe(ms)]
            }
        }
        if let map = dns as? [String: Any] {
            return map.sorted { $0.key < $1.key }
                .map { [describe($0.key), describe($0.value)] }
        }
        return []
    }

    // MARK: JSON

    /// JSON layout: a small envelope carrying run identity plus the result
    /// itself. When `raw` parses as JSON it nests under `"result"` (matching
    /// the CLI exporter's pretty-JSON spirit); otherwise the original text
    /// is preserved under `"result_raw"`. Keys sorted, trailing newline.
    private static func jsonText(for r: ExportRecord) -> String {
        var envelope: [String: Any] = [
            "timestamp": iso8601(r.ts),
            "mode": r.mode,
            "params": r.params,
        ]
        if let parsed = parsedJSONObject(r.raw) {
            envelope["result"] = parsed
        } else {
            envelope["result_raw"] = r.raw
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            // Unreachable for dictionary envelopes built above, but stay total.
            return "{\n  \"timestamp\": \"\(iso8601(r.ts))\",\n  \"mode\": \"\(r.mode)\"\n}\n"
        }
        return text + "\n"
    }

    // MARK: Shared parsing helpers (pure)

    private static func parsedJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }

    /// Distinguishes real JSON booleans from numeric values: on Apple
    /// platforms both bridge to NSNumber, so `objNumber as? Bool` succeeds
    /// even for `0`/`1` (and would render `dropped: 0` as `false`). CFBoolean
    /// tags exist only for genuine boolean literals.
    private static func isBooleanValue(_ n: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #endif
    }

    private static func describeIfScalar(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case is String, is NSNumber:
            return describe(value)
        default:
            return nil // nested dict/array: not a scalar column
        }
    }

    /// Render any JSON value as a flat cell string. Numbers ride NSNumber's
    /// shortest round-trip description — checked BEFORE Bool so numeric JSON
    /// values (which bridge to NSNumber) never render as true/false. Booleans
    /// stay lowercase; containers collapse to compact JSON.
    private static func describe(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let number = value as? NSNumber {
            // Genuine JSON boolean literal → true/false; any other number
            // → shortest numeric description (see isBooleanValue).
            if isBooleanValue(number) {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    /// Contract-P2-style timestamp (`2026-08-23T14:30:00Z`, UTC).
    private static func iso8601(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    // MARK: Saving (AppKit)

    /// Present an NSSavePanel pre-filled for this record/format and write the
    /// export atomically. Default filename: `netmax-<mode>-<timestamp>.<ext>`.
    ///
    /// - Returns: the URL the user chose (file exists and holds the export).
    /// - Throws: `ExportError.cancelled` when the panel is dismissed, or any
    ///   write error surfaced by FileManager.
    #if canImport(AppKit)
    @MainActor
    static func save(_ r: ExportRecord, as f: ExportFormat) async throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "netmax-\(r.mode)-\(filenameStamp(r.ts)).\(f.fileExtension)"
        panel.allowedContentTypes = [f.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Save the last result (\(r.mode)) as \(f.displayName)."

        // `begin` keeps us off the blocking runModal path and works with or
        // without a parent window (menu-bar popover has none).
        let response: NSApplication.ModalResponse = await withCheckedContinuation {
            continuation in
            panel.begin { resp in continuation.resume(returning: resp) }
        }

        guard response == .OK, let destination = panel.url else {
            throw ExportError.cancelled
        }

        let text = format(r, as: f)
        guard let data = text.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    /// Filesystem-safe UTC stamp for default filenames
    /// (`2026-08-23T07-15-09Z` — colons swapped out for portability).
    private static func filenameStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.string(from: date)
    }
    #endif
}
