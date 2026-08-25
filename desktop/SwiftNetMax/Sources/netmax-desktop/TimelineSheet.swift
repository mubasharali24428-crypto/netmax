import SwiftUI

/// W5 wiring (C1/P1) — sheet hosting the QoE timeline: range picker + Canvas
/// lanes + event markers overlay, per the TimelineEventMarkers seam contract.
struct TimelineSheet: View {
    /// Prebuilt timeline rows (history samples merged with wifi events).
    let rows: [TimelineRow]

    @State private var range: TimelineRange = .oneDay
    @Environment(\.dismiss) private var dismiss

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
                QoETimelineView(rows: rows, events: events, range: $range)
                    .overlay(alignment: .top) {
                        TimelineEventMarkers.overlay(
                            rows: windowRows,
                            events: events,
                            dateToX: { _ in nil }, // markers self-position via row geometry
                            metric: .mbps
                        )
                    }
                    .padding(.horizontal)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .padding(.bottom)
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
