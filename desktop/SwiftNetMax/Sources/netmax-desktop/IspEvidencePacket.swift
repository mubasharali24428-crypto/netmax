//
//  IspEvidencePacket.swift
//  netmax-desktop
//
//  Task 3 — ISP evidence packet: a plain-text/markdown export of the
//  chronological degraded-run timeline plus plan-vs-actual speeds, suitable
//  for pasting into an ISP support ticket. Pure `format` (Foundation only)
//  + AppKit save, mirroring ReportExport.swift's split.
//

import Foundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

enum IspEvidencePacket {
    // MARK: Pure format (no AppKit — offline-testable)

    /// Markdown timeline of every degraded run + plan-vs-actual summary.
    /// - Parameters:
    ///   - records: full history, oldest-first (HistoryStore order).
    ///   - planMbps: user's stated plan from Settings (`netmax.plan.mbps`).
    /// - Returns: markdown text ready to save/paste.
    static func format(records: [HistoryRecord], planMbps: Double?) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss z"

        var lines: [String] = []
        lines.append("# NetMax ISP Evidence Packet")
        lines.append("")
        lines.append("Generated: \(fmt.string(from: Date()))")
        lines.append("Runs included: \(records.count)")
        if let planMbps {
            lines.append(String(format: "Plan speed: %.0f Mbps", planMbps))
        } else {
            lines.append("Plan speed: not set")
        }
        lines.append("")

        // Plan-vs-actual: average + peak of recognizable speeds.
        let speeds = records.compactMap {
            MetricExtractor.latestSpeedMbps(in: $0.resultRaw)
        }
        lines.append("## Plan vs actual")
        lines.append("")
        if speeds.isEmpty {
            lines.append("- No measurable speed runs yet.")
        } else {
            let avg = speeds.reduce(0, +) / Double(speeds.count)
            let peak = speeds.max() ?? avg
            lines.append(String(format: "- Average measured: %.1f Mbps", avg))
            lines.append(String(format: "- Peak measured: %.1f Mbps", peak))
            if let planMbps, planMbps > 0 {
                let pct = avg / planMbps * 100
                lines.append(String(format: "- Average vs plan: %.0f%% of %.0f Mbps",
                                    pct, planMbps))
                if pct < 80 {
                    lines.append("- **Shortfall:** average is more than 20% below plan — "
                        + "worth escalating with this data.")
                }
            }
        }
        lines.append("")

        // Degradation timeline via the same pure rules the alerts use.
        let alerts = evaluateDegradation(records)
        lines.append("## Degradation timeline")
        lines.append("")
        if alerts.isEmpty {
            lines.append("No degradation events recorded between consecutive runs.")
        } else {
            lines.append("| # | When | Mode | Event |")
            lines.append("|---|------|------|-------|")
            for (i, alert) in alerts.enumerated() {
                // newerIndex is into the `records` array we passed in.
                let ts: String
                let mode: String
                if alert.newerIndex >= 0 && alert.newerIndex < records.count {
                    ts = fmt.string(from: records[alert.newerIndex].ts)
                    mode = records[alert.newerIndex].mode
                } else {
                    ts = "—"
                    mode = "—"
                }
                // Escape pipes so markdown tables stay intact.
                let text = alert.text.replacingOccurrences(of: "|", with: "\\|")
                lines.append("| \(i + 1) | \(ts) | \(mode) | \(text) |")
            }
        }
        lines.append("")

        lines.append("## Recent runs (newest last)")
        lines.append("")
        lines.append("| When | Mode | Speed (Mbps) | Grade | Loss (%) |")
        lines.append("|------|------|--------------|-------|----------|")
        let recent = records.suffix(20)
        for r in recent {
            let speed = MetricExtractor.latestSpeedMbps(in: r.resultRaw)
                .map { String(format: "%.1f", $0) } ?? "—"
            let grade = MetricExtractor.latestBloatGrade(in: r.resultRaw)?.letter ?? "—"
            let loss = MetricExtractor.latestPacketLossPercent(in: r.resultRaw)
                .map { String(format: "%.2f", $0) } ?? "—"
            lines.append("| \(fmt.string(from: r.ts)) | \(r.mode) | \(speed) | \(grade) | \(loss) |")
        }
        lines.append("")
        lines.append("---")
        lines.append("_Honest limits: results reflect conditions at test time; "
            + "they do not guarantee peak speed or prove ISP fault on their own._")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: AppKit save

    #if canImport(AppKit)
    /// Save-panel export. Returns the URL on success, nil on cancel/error.
    static func export(records: [HistoryRecord], planMbps: Double?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "netmax-isp-evidence.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let text = format(records: records, planMbps: planMbps)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            #if DEBUG
            print("[IspEvidence] write failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
    #endif
}

// MARK: - Offline self-checks

#if DEBUG
enum IspEvidenceTests {
    @discardableResult
    static func runAll(now: Date = Date()) -> Int {
        var failures = 0
        func check(_ cond: Bool) { failures += cond ? 0 : 1 }

        let good = #"{"mbps": 90.0, "grade": "A", "loss": 0.1}"#
        let bad = #"{"mbps": 40.0, "grade": "D", "loss": 5.5}"#
        let records = [
            HistoryRecord(ts: now.addingTimeInterval(-7200), mode: "baseline",
                          params: [:], resultRaw: good),
            HistoryRecord(ts: now.addingTimeInterval(-3600), mode: "bloat",
                          params: [:], resultRaw: bad),
            HistoryRecord(ts: now.addingTimeInterval(-60), mode: "baseline",
                          params: [:], resultRaw: good),
        ]

        let md = IspEvidencePacket.format(records: records, planMbps: 100)
        check(md.contains("# NetMax ISP Evidence Packet"))
        check(md.contains("Plan speed: 100 Mbps"))
        check(md.contains("## Plan vs actual"))
        check(md.contains("## Degradation timeline"))
        check(md.contains("Bufferbloat grade dropped") || md.contains("Packet loss"))
        check(md.contains("| When | Mode | Speed (Mbps) | Grade | Loss (%) |"))
        check(md.contains("Honest limits"))

        // Empty history still produces a usable packet.
        let empty = IspEvidencePacket.format(records: [], planMbps: nil)
        check(empty.contains("Plan speed: not set"))
        check(empty.contains("No degradation events"))

        return failures
    }
}
#endif
