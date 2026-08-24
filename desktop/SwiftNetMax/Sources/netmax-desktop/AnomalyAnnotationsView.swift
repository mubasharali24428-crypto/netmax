//
//  AnomalyAnnotationsView.swift
//  netmax-desktop
//
//  TEAM-2 T2-b (W4 X5 oracle lane) — UI half of the anomaly oracle.
//  Consumes AnomalyEngine.swift (T2-a) and renders its findings with
//  confidence-law wording: readings are described as "unusual" / "differs
//  from your typical …", never as broken or problematic.
//
//  Components:
//      AnomalyMarker            — small "!" badge for sparkline/history rows,
//                                 hover shows a tooltip-style detail card.
//      AnomalyMarkersOverlay    — positions one marker per anomaly across a
//                                 series (sparkline overlay).
//      DashboardBadge           — banner shown on the dashboard when an
//                                 anomaly exists in the last 5 runs, linking
//                                 to the History tab.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WIRING NOTES FOR OTHER LANES (nothing outside this file is edited):
//
//  1. Sparklines (DashboardCardsView.speedTrendSection, HistoryView
//     TrendChart): overlay the chart content with markers keyed to the same
//     sample array the curve draws:
//
//         let anomalies = AnomalyEngine.anomalies(
//             in: AnomalyEngine.extractSeries(records, metric: .mbps))
//         SparklineView(series, style: .line)
//             .overlay(alignment: .top) {
//                 AnomalyMarkersOverlay(values: series, anomalies: anomalies)
//             }
//
//     The overlay maps anomaly.index → horizontal position exactly like
//     SparklineView's line mode spaces points (see `xPosition`), so markers
//     sit on the data point they describe. For `.bars`-style charts pass
//     `slotSpacing: true` to match bar-slot geometry instead.
//
//  2. History rows (HistoryRow in HistoryView.swift): rows are built per
//     record; compute that record's index inside the SAME oldest-first
//     series used above, then append the marker after the mode capsule:
//
//         if let anomaly = anomalies.first(where: { $0.index == rowIndex }) {
//             HStack(spacing: 6) {
//                 Text(record.mode)…
//                 AnomalyMarker(anomaly: anomaly, metric: .mbps)
//             }
//         }
//
//  3. Dashboard badge (DashboardCardsView.cardRow area): one line above the
//     cards —
//
//         if let recent = AnomalyEngine.recentAnomalies(
//                 records: records, metric: .mbps, lookback: 5).last {
//             DashboardBadge(anomaly: recent, metric: .mbps) {
//                 // switch to History (tag 2); RootView owns selection
//             }
//         }
//
//     `recentAnomalies(lookback: 5)` applies the engine's quiet gate over
//     the full series first, so badges never appear on thin history (<10
//     usable samples of that metric).
//  ─────────────────────────────────────────────────────────────────────────
//

import SwiftUI

// MARK: - Marker

/// Small "!" badge marking an unusual reading; hover reveals detail text.
///
/// Purely presentational: everything arrives through the initializer. Color
/// comes from ThemeTokens' WCAG-calibrated ramp (grade D orange for notable,
/// grade F red for pronounced) so it stays readable in light and dark mode
/// and never uses the stock palette that fails AA contrast.
struct AnomalyMarker: View {

    let anomaly: Anomaly
    let metric: AnomalyMetric

    /// Show severity by color only, or also vary the badge fill? Default
    /// renders both tiers as an outlined "!" capsule; set `filled` for a
    /// stronger look on dense charts.
    var filled: Bool = false

    var body: some View {
        Text("!")
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(filled ? tint.opacity(0.22) : Color.clear)
            )
            .overlay(Capsule().strokeBorder(tint.opacity(0.8)))
            .help(tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Unusual reading marker")
            .accessibilityValue(accessibilityText)
    }

    /// Tooltip-style detail text — full confidence-law wording from T2-a.
    private var tooltip: String {
        AnomalyEngine.describe(anomaly, metric: metric)
    }

    /// Spoken version of the tooltip (VoiceOver reads this instead).
    private var accessibilityText: String { tooltip }

    private var tint: Color {
        switch anomaly.severity {
        case .notable: return Theme.gradeD
        case .pronounced: return Theme.gradeF
        }
    }
}

// MARK: - Overlay

/// Positions one ``AnomalyMarker`` per anomaly across a sparkline-width row.
///
/// Geometry mirrors SparklineView: line mode spreads points evenly from left
/// edge to right edge (index / count−1); bars mode divides the width into
/// equal slots (index × slot + slot/2). Pass the matching flag so markers
/// align with whichever style the underlying chart draws.
struct AnomalyMarkersOverlay: View {

    /// The values the chart draws (same array passed to SparklineView).
    let values: [Double]

    /// Flags whose `index` refers into `values`.
    let anomalies: [Anomaly]

    /// True when overlaying a `.bars`-style chart (slot geometry).
    var slotSpacing: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(anomalies, id: \.index) { anomaly in
                    AnomalyMarker(anomaly: anomaly, metric: .mbps)
                        .position(x: xPosition(for: anomaly.index, width: geo.size.width),
                                  y: geo.size.height * 0.5)
                }
            }
            .allowsHitTesting(true)
        }
        .accessibilityHidden(true) // markers already speak via their own elements
    }

    /// Same horizontal math SparklineView uses per style.
    private func xPosition(for index: Int, width: CGFloat) -> CGFloat {
        guard values.count > 1 else { return width / 2 }
        if slotSpacing {
            let slot = width / CGFloat(values.count)
            return CGFloat(index) * slot + slot / 2
        }
        return width * CGFloat(index) / CGFloat(values.count - 1)
    }
}

// MARK: - Dashboard badge

/// Banner for the dashboard tab: appears when the most recent runs contain
/// an unusual reading, links to History for the full picture.
///
/// Shown only when `AnomalyEngine.recentAnomalies(records:metric:lookback:)`
/// returns something — which itself is gated behind ≥10 usable samples, so
/// fresh installs never see speculative warnings. Wording obeys the
/// confidence law ("unusual", "differs from your typical").
struct DashboardBadge: View {

    let anomaly: Anomaly
    let metric: AnomalyMetric
    /// Invoked when the user taps "Open History"; the host wires this to
    /// switching the TabView selection (History = tag 2).
    let action: () -> Void

    @State private var dismissed = false

    init(anomaly: Anomaly, metric: AnomalyMetric, action: @escaping () -> Void) {
        self.anomaly = anomaly
        self.metric = metric
        self.action = action
    }

    var body: some View {
        if !dismissed {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(AnomalyEngine.brief(anomaly, metric: metric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }

                Spacer(minLength: 4)

                Button(action: action) {
                    Label("Open History", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction) // Return activates when banner focused

                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss this note for now")
                .accessibilityLabel("Dismiss unusual reading note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.45))
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(bannerAccessibilityLabel)
        }
    }

    // MARK: Wording (confidence law)

    private var headline: String {
        "Your latest \(metric.displayName) reading looks unusual"
    }

    private var bannerAccessibilityLabel: String {
        headline + ". " + AnomalyEngine.describe(anomaly, metric: metric)
    }

    private var tint: Color {
        switch anomaly.severity {
        case .notable: return Theme.gradeD
        case .pronounced: return Theme.gradeF
        }
    }
}

// MARK: - Offline self-checks
//
// Package.swift has no test target; these compile into DEBUG builds as plain
// static checks mirroring DashboardCardsTests/AnomalyEngineTests conventions.

#if DEBUG
enum AnomalyAnnotationsTests {

    @discardableResult
    static func runAll(now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[AnomalyAnnotationsTests] FAIL: \(name)") }
        }

        let samples = (0..<20).map { i in
            MetricSample(ts: now.addingTimeInterval(Double(i) * 60),
                         value: i == 14 ? 260 : 100)
        }
        let flags = AnomalyEngine.anomalies(in: samples)
        check(flags.count == 1 && flags[0].index == 14, "annotations fixture flags idx 14")

        // Marker wording obeys the confidence law.
        for text in [AnomalyEngine.describe(flags[0], metric: .mbps),
                     AnomalyEngine.brief(flags[0], metric: .mbps),
                     "Your latest speed reading looks unusual"] {
            let lowered = text.lowercased()
            check(!lowered.contains("broken") && !lowered.contains("problem"),
                  "marker/badge wording avoids broken/problem (\(text))")
            check(lowered.contains("usual") || lowered.contains("typical"),
                  "wording frames against typical readings")
        }

        // Quiet gate holds at the UI query layer too.
        let thinRecords = (0..<9).map { i in
            HistoryRecord(ts: now.addingTimeInterval(Double(i)),
                          mode: "turbo", params: [:],
                          resultRaw: "{\"mbps\": \(i == 4 ? 900 : 100)}")
        }
        check(AnomalyEngine.recentAnomalies(records: thinRecords, metric: .mbps).isEmpty,
              "badge source: 9-sample spike stays quiet")

        return failures
    }
}
#endif

// MARK: - Previews

#if DEBUG
#Preview("Marker tiers") {
    let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let notable = Anomaly(index: 3, ts: base, value: 128, expected: 101, severity: .notable)
    let pronounced = Anomaly(index: 7, ts: base, value: 260, expected: 100, severity: .pronounced)
    return VStack(spacing: 18) {
        HStack { Text("mode capsule"); AnomalyMarker(anomaly: notable, metric: .mbps) }
        HStack { Text("pronounced"); AnomalyMarker(anomaly: pronounced, metric: .mbps) }
        HStack { Text("filled"); AnomalyMarker(anomaly: pronounced, metric: .mbps, filled: true) }
    }
    .padding(30)
}

#Preview("Sparkline overlay") {
    let values = (0..<20).map { $0 == 14 ? 260.0 : 100.0 }
    let stamps = (0..<values.count).map { Date(timeIntervalSinceReferenceDate: Double($0) * 60) }
    let samples = zip(stamps, values).map { MetricSample(ts: $0, value: $1) }
    return SparklineView(values, style: .line)
        .overlay(AnomalyMarkersOverlay(values: values,
                                       anomalies: AnomalyEngine.anomalies(in: samples)))
        .padding(40)
        .frame(width: 420)
}

#Preview("Dashboard badge") {
    let anomaly = Anomaly(index: 17, ts: Date(), value: 262, expected: 102, severity: .pronounced)
    return VStack {
        DashboardBadge(anomaly: anomaly, metric: .mbps) {}
    }
    .padding(24)
}
#endif
