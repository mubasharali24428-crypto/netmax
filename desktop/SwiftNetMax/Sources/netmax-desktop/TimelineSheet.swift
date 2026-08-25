import SwiftUI

/// W5 wiring (C1/P1) — sheet hosting the QoE timeline: range picker + Canvas
/// lanes + event markers overlay, per the TimelineEventMarkers seam contract.
struct TimelineSheet: View {
    /// Prebuilt timeline rows (history samples merged with wifi events).
    let rows: [TimelineRow]

    @State private var range: TimelineRange = .oneDay
    /// T2-c (W11-A-015): nearest-sample readout while the pointer moves over
    /// the lanes; nil whenever the pointer leaves the chart.
    @State private var hoverReadout: String?
    @Environment(\.dismiss) private var dismiss

    /// Leading inset added by this sheet's own `.padding(.horizontal)` around
    /// the chart — the hover math subtracts it to recover the plot rect U1's
    /// Canvases draw into (they share this view's leading/trailing edges).
    private static let chartHorizontalInset: CGFloat = 16

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Quality Timeline")
                    .font(.headline)
                Spacer()
                TimelineRangePicker(selection: $range)
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(NetMaxPressStyle()) // W8 A1
                .help("Close the timeline")
                .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])
            .padding(.vertical, 6)
            .background(.ultraThinMaterial) // W8 A2: chrome reads as material

            // T2-c (W11-A-026): plain-language event census for the visible
            // window, shown only when the range actually contains events.
            if !events.isEmpty {
                Text(Self.eventCountText(events.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("timeline.eventCount")
            }

            if windowRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.dots.scatter")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No measurements in this period")
                        .font(.headline)
                    Text("Run a test or enable scheduled checks to fill the timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // T2-c (W11-A-025): lane legend above the chart; the live
                // hover readout shares the row so values never cover data.
                HStack {
                    laneLegend
                    Spacer()
                    if let readout = hoverReadout {
                        Text(readout)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .transition(.opacity)
                            .accessibilityLabel("Value under pointer")
                            .accessibilityValue(readout)
                    }
                }
                .padding(.horizontal)

                GeometryReader { geo in
                    QoETimelineView(rows: rows, events: events, range: $range)
                        .overlay(alignment: .top) {
                            TimelineEventMarkers.overlay(
                                rows: windowRows,
                                events: events,
                                dateToX: { _ in nil }, // markers self-position via row geometry
                                metric: .mbps
                            )
                        }
                        // T2-c (W11-A-015): track the pointer and surface the
                        // nearest sample's values at that instant.
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hoverReadout = Self.readout(atX: point.x,
                                                            viewWidth: geo.size.width,
                                                            rows: windowRows)
                            case .ended:
                                hoverReadout = nil
                            }
                        }
                }
                .padding(.horizontal)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .padding(.bottom)
    }

    // MARK: - T2-c discoverability additions

    /// Three small color dots naming the lanes. All lanes currently stroke
    /// `Theme.accent`, so every dot carries that token — distinct colors here
    /// would claim a distinction the chart doesn't have.
    private var laneLegend: some View {
        HStack(spacing: 10) {
            legendDot("mbps")
            legendDot("loss")
            legendDot("jitter")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lanes: throughput, packet loss, jitter")
        .help("Throughput (Mbps), packet loss (%), and jitter (ms) over time. "
            + "Gaps mean no measurement was recorded at that moment.")
    }

    private func legendDot(_ label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// "3 WiFi events in range" / singular variant.
    private static func eventCountText(_ count: Int) -> String {
        count == 1 ? "1 WiFi event in range" : "\(count) WiFi events in range"
    }

    /// Nearest-sample sentence for the pointer at `x` (in the padded sheet
    /// coordinate space), mirroring QoETimelineView.drawLane's time→x mapping
    /// in reverse: the mbps lane spans its own first…last sample across the
    /// full plot width. Nil when the mbps lane has no drawable series (<2
    /// points) — guessing a time axis that isn't drawn would be dishonest.
    static func readout(atX x: CGFloat, viewWidth: CGFloat, rows: [TimelineRow]) -> String? {
        let samples = rows.compactMap { row -> Date? in row.mbps != nil ? row.ts : nil }
        guard samples.count >= 2,
              let start = samples.first, let end = samples.last else { return nil }

        let plotWidth = viewWidth - 2 * chartHorizontalInset
        guard plotWidth > 0 else { return nil }
        let fraction = min(max((x - chartHorizontalInset) / plotWidth, 0), 1)

        let span = max(end.timeIntervalSince(start), 1)
        let target = start.addingTimeInterval(span * Double(fraction))

        // Nearest row in TIME (any row, marker-only included); ties → earlier.
        guard let nearest = rows.min(by: {
            let a = abs($0.ts.timeIntervalSince(target))
            let b = abs($1.ts.timeIntervalSince(target))
            return a == b ? $0.ts < $1.ts : a < b
        }) else { return nil }

        return describe(nearest)
    }

    /// One-line honest description of a row: time plus whichever metrics the
    /// payload actually carried (nils omitted — never zero-filled).
    private static func describe(_ row: TimelineRow) -> String {
        var parts: [String] = []
        if let mbps = row.mbps {
            parts.append(mbps == mbps.rounded()
                         ? String(Int(mbps)) + " Mbps"
                         : String(format: "%.1f Mbps", mbps))
        }
        if let loss = row.lossPct {
            parts.append(String(format: "%.1f%% loss", loss))
        }
        if let jitter = row.jitterMs {
            parts.append(String(format: "%.1f ms jitter", jitter))
        }
        if parts.isEmpty {
            parts.append(row.eventId != nil ? "wifi event" : "no values recorded")
        }
        return row.ts.formatted(date: .abbreviated, time: .standard) + " · " + parts.joined(separator: " · ")
    }

    // MARK: - Range filtering

    private var windowStart: Date { Date().addingTimeInterval(-range.seconds) }

    private var windowRows: [TimelineRow] {
        rows.filter { $0.ts >= windowStart }
    }

    private var events: [WifiEvent] {
        // The model embeds each event into its merged row; reconstructing the
        // WifiEvent values for the marker layer keeps one source of truth.
        windowRows.compactMap { row -> WifiEvent? in
            guard let id = row.eventId else { return nil }
            return WifiEvent(ts: row.ts, kind: "unknown", id: id)
        }
    }
}
