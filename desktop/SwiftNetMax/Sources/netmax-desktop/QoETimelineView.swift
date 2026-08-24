import SwiftUI

/// W5-U1 — the QoE timeline: three stacked Canvas lanes (mbps / loss% / jitter)
/// sharing one time X-axis, with honest gaps (nil metrics = line breaks).
///
/// Seam: exposes `dateToX(for:in:)` so `TimelineEventMarkers.overlay` can
/// position event markers pixel-aligned on this view's time axis (see
/// TimelineEventMarkers.swift header for the overlay integration snippet).
struct QoETimelineView: View {
    let rows: [TimelineRow]
    let events: [WifiEvent]
    @Binding var range: TimelineRange

    var body: some View {
        Group {
            if filteredRows.isEmpty {
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
                .accessibilityElement(children: .combine)
            } else {
                GeometryReader { proxy in
                    VStack(spacing: 10) {
                        laneCanvas(metric: .mbps, label: "Throughput", unit: "Mbps", height: laneHeight(in: proxy.size))
                        laneCanvas(metric: .loss, label: "Packet loss", unit: "%", height: laneHeight(in: proxy.size))
                        laneCanvas(metric: .jitter, label: "Jitter", unit: "ms", height: laneHeight(in: proxy.size))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            }
        }
    }

    // MARK: - Range filtering

    private var windowStart: Date { Date().addingTimeInterval(-range.seconds) }

    private var filteredRows: [TimelineRow] {
        rows.filter { $0.ts >= windowStart }
    }

    private func samples(_ metric: CorrelationMetric) -> [MetricSample] {
        filteredRows.compactMap { row in
            guard let v = metric.value(in: row) else { return nil }
            return MetricSample(ts: row.ts, value: v)
        }
    }

    // MARK: - Lane drawing

    private func laneHeight(in size: CGSize) -> CGFloat {
        max(70, (size.height - 20) / 3)
    }

    private func laneCanvas(metric: CorrelationMetric, label: String, unit: String, height: CGFloat) -> some View {
        let samples = samples(metric)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).fontWeight(.semibold)
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                drawLane(metric, in: context, size: size, samples: samples)
            }
            .frame(height: height)
        }
        .accessibilityHidden(true) // lanes are decorative; summary lives on the parent
    }

    private func drawLane(
        _ metric: CorrelationMetric, in context: GraphicsContext,
        size: CGSize, samples: [MetricSample]
    ) {
        guard samples.count >= 2, let start = samples.first?.ts, let end = samples.last?.ts else {
            // Fewer than 2 points can't form a line — draw the honest baseline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            return
        }

        let span = max(end.timeIntervalSince(start), 1)
        let values = samples.map(\.value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.1, 0.5)

        func x(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(start) / span) * size.width
        }
        func y(_ value: Double) -> CGFloat {
            let clamped = min(max(value, lo - pad), hi + pad)
            return size.height - CGFloat((clamped - (lo - pad)) / ((hi + pad) - (lo - pad))) * size.height
        }

        var path = Path()
        var penDown = false
        for sample in samples {
            if sample.value.isFinite {
                let point = CGPoint(x: x(sample.ts), y: y(sample.value))
                if penDown { path.addLine(to: point) } else { path.move(to: point); penDown = true }
            } else {
                penDown = false // honest gap: nil/non-finite breaks the line
            }
        }
        context.stroke(
            path,
            with: .color(Theme.accent),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }

    private var accessibilitySummary: String {
        let count = filteredRows.count
        return """
        Quality timeline, \(range.displayName): \(count) measurements across \
        throughput, packet loss, and jitter lanes.
        """
    }
}
