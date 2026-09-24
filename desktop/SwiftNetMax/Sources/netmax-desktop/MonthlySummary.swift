//
//  MonthlySummary.swift
//  netmax-desktop
//
//  Task 4 view decomposition — Monthly Summary model (W13B UB-2, S-009)
//  extracted from ReportsView. Pure computation over injected records +
//  clock; ReportsMonthlyTests stay at the bottom of ReportsView.
//  No behavior change: same types, same names, same module.
//

import Foundation

// MARK: - Monthly summary model (W13B UB-2, S-009)

/// Aggregated last-N-days stats behind the Monthly Summary card/PDF.
/// Pure computation over injected records + clock so it is offline-checkable.
struct MonthlySummaryStats: Equatable {
    /// Runs recorded inside the window.
    let testsCount: Int
    /// Mean of recognizable Mbps values in the window; nil when none parse.
    let averageMbps: Double?
    /// Worst bufferbloat grade letter seen in the window (Waveform rubric
    /// order); nil when no payload carried a grade.
    let worstGrade: String?
    /// Total unusual readings flagged by AnomalyEngine across mbps / loss /
    /// jitter within the window (quiet gate respected: thin data counts 0).
    let anomalyCount: Int
}

enum MonthlySummary {
    /// Default analysis window in days.
    static let windowDays = 30

    /// Compute the last-`days`-day summary. Records may arrive in any order;
    /// timestamps decide membership. `now` is injectable for determinism.
    static func compute(from records: [HistoryRecord],
                        now: Date = Date(),
                        days: Int = windowDays) -> MonthlySummaryStats {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let window = records.filter { $0.ts >= cutoff }

        // Average speed through the SAME extractor the dashboard cards use,
        // so the headline number can never disagree with the cards.
        let speeds = window.compactMap { MetricExtractor.latestSpeedMbps(in: $0.resultRaw) }
        let average = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)

        // Worst grade by the engine's Waveform rubric order (A+ … F).
        let gradeOrder = NotificationRules.gradeOrder
        let letters = window.compactMap {
            MetricExtractor.latestBloatGrade(in: $0.resultRaw)?.letter
        }
        let worst = letters.compactMap { gradeOrder.firstIndex(of: $0) }.max()
            .map { gradeOrder[$0] }

        // Unusual readings: MAD-flagged points per metric, summed across
        // mbps/loss/jitter. The engine's quiet gate keeps thin data silent.
        let anomalies = AnomalyMetric.allCases.reduce(0) { total, metric in
            let series = AnomalyEngine.extractSeries(window, metric: metric)
            return total + AnomalyEngine.anomalies(in: series).count
        }

        return MonthlySummaryStats(testsCount: window.count,
                                   averageMbps: average,
                                   worstGrade: worst,
                                   anomalyCount: anomalies)
    }

    /// Human date-range line for the card/PDF header, e.g. "Jul 27 – Aug 26".
    static func dateRangeText(from start: Date, to end: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }

    /// Map the stats onto ReportCardPDF's renderer input. Score bars: only
    /// average speed carries one (tiered like the dashboard's own ladder);
    /// counts honestly render without bars.
    static func pdfContent(for stats: MonthlySummaryStats,
                           days: Int = windowDays) -> ReportCardPDF.Content {
        var speedScore: Double?
        if let avg = stats.averageMbps {
            speedScore = avg >= 100 ? 1.0 : avg >= 50 ? 0.75 : avg >= 25 ? 0.5 : 0.25
        }
        let speedValue = stats.averageMbps.map {
            String(format: "%.1f Mbps", $0)
        } ?? "no measurable runs"
        let rows: [ReportCardPDF.Content.Row] = [
            .init(metric: "Tests run", value: "\(stats.testsCount)", score: nil),
            .init(metric: "Average speed", value: speedValue, score: speedScore),
            .init(metric: "Worst bufferbloat grade",
                  value: stats.worstGrade ?? "—", score: nil),
            .init(metric: "Unusual readings", value: "\(stats.anomalyCount)", score: nil),
        ]
        return ReportCardPDF.Content(
            title: "NetMax Monthly Summary",
            dateRangeText: "Last \(days) days · "
                + dateRangeText(from: Date().addingTimeInterval(-Double(days) * 86_400),
                                to: Date()),
            overallGrade: stats.worstGrade ?? "—",
            sections: [.init(heading: "Monthly overview", rows: rows)],
            limitsFooter:
                "Honest limits: aggregates describe when you tested — quiet weeks say little."
        )
    }
}
