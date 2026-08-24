import SwiftUI

/// Rendering style for ``SparklineView``.
enum SparklineStyle {
    /// One rounded bar per value, heights scaled between the series' min/max.
    case bars
    /// Smooth Catmull-Rom curve through the values, with a soft area fill.
    case line
}

/// Reusable sparkline: given a `[Double]`, draws a compact bar or smooth-line
/// chart scaled to the series min/max. Pure drawing — no data fetching, no
/// state; callers (dashboard, history trends) own the data.
///
/// Usage:
///
///     SparklineView(samples)                                  // accent bars, 48pt
///     SparklineView(samples, style: .line, color: .orange)    // smooth line
///     SparklineView(samples, height: 64)                      // taller
///
/// Behavior notes:
/// - Empty input (or input with no finite numbers) renders a dashed
///   "no data" placeholder instead of blank space.
/// - A constant series reads as a mid-height row rather than dividing by zero.
/// - Non-finite values (`nan`, `inf`) are ignored.
struct SparklineView: View {
    // MARK: - Inputs

    private let series: [Double]
    private let style: SparklineStyle
    private let color: Color
    private let height: CGFloat

    /// - Parameters:
    ///   - values: Numeric samples, oldest-first (drawn left → right).
    ///   - style: Bar chart or smooth line. Defaults to `.bars`.
    ///   - color: Stroke/fill tint. Defaults to the app accent color.
    ///   - height: Canvas height in points. Defaults to 48.
    init(
        _ values: [Double],
        style: SparklineStyle = .bars,
        color: Color = .accentColor,
        height: CGFloat = 48
    ) {
        self.series = values.filter(\.isFinite)
        self.style = style
        self.color = color
        self.height = height
    }

    // MARK: - Body

    var body: some View {
        if series.isEmpty {
            placeholder
        } else {
            Canvas { context, size in
                switch style {
                case .bars: drawBars(in: &context, size: size)
                case .line: drawLine(in: &context, size: size)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sparkline")
            .accessibilityValue(accessibilitySummary)
        }
    }

    // MARK: - Zero-data placeholder

    /// Visible stand-in for empty data so layouts don't collapse silently.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(
                color.opacity(0.3),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                Text("no data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sparkline")
            .accessibilityValue("no data")
    }

    // MARK: - Bars

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        // Small vertical inset so even full-height bars never clip their cap.
        let inset: CGFloat = 2
        let drawable = CGRect(
            x: 0,
            y: inset,
            width: size.width,
            height: max(0, size.height - inset * 2)
        )

        let lo = series.min() ?? 0
        let hi = series.max() ?? 0
        let slot = drawable.width / CGFloat(series.count)
        let gap = min(3, slot * 0.25) // breathe between bars; shrinks when dense
        let barWidth = max(1, slot - gap)

        for (index, value) in series.enumerated() {
            let fraction = normalized(value, low: lo, high: hi)
            let barHeight = max(2, CGFloat(fraction) * drawable.height)
            let x = drawable.minX + CGFloat(index) * slot + gap / 2
            let barRect = CGRect(
                x: x,
                y: drawable.maxY - barHeight,
                width: barWidth,
                height: barHeight
            )
            let radius = min(barWidth / 2, barHeight / 2)
            context.fill(
                Path(roundedRect: barRect, cornerRadius: radius),
                with: .color(color.opacity(0.75))
            )
        }
    }

    // MARK: - Line

    private func drawLine(in context: inout GraphicsContext, size: CGSize) {
        // Small vertical inset so the stroke never clips at the extremes.
        let inset: CGFloat = 2
        let drawable = CGRect(
            x: 0,
            y: inset,
            width: size.width,
            height: max(0, size.height - inset * 2)
        )

        let lo = series.min() ?? 0
        let hi = series.max() ?? 0
        let points = series.enumerated().map { index, value -> CGPoint in
            let x: CGFloat
            if series.count == 1 {
                x = drawable.midX
            } else {
                x = drawable.minX + drawable.width * CGFloat(index) / CGFloat(series.count - 1)
            }
            // Invert Y: higher value → closer to the top.
            let y = drawable.maxY - CGFloat(normalized(value, low: lo, high: hi)) * drawable.height
            return CGPoint(x: x, y: y)
        }

        // Soft fill under the curve.
        if let last = points.last, let first = points.first {
            var area = Self.smoothPath(through: points)
            area.addLine(to: CGPoint(x: last.x, y: drawable.maxY))
            area.addLine(to: CGPoint(x: first.x, y: drawable.maxY))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.25), .clear]),
                    startPoint: CGPoint(x: 0, y: drawable.minY),
                    endPoint: CGPoint(x: 0, y: drawable.maxY)
                )
            )
        }

        if series.count == 1 {
            // A lone sample can't form a line; show a dot instead.
            let dotRect = CGRect(
                x: points[0].x - 2.5,
                y: points[0].y - 2.5,
                width: 5,
                height: 5
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
            return
        }

        var stroke = Self.smoothPath(through: points)
        stroke = stroke.strokedPath(
            StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
        context.fill(stroke, with: .color(color))
    }

    // MARK: - Scaling helpers

    /// Maps `value` into 0...1 across `[low, high]`. A constant (or degenerate)
    /// series maps to 0.5 so it reads as a mid-height baseline, never ÷0.
    private func normalized(_ value: Double, low: Double, high: Double) -> Double {
        guard high > low else { return 0.5 }
        return (value - low) / (high - low)
    }

    /// Catmull-Rom spline through `points`, emitted as cubic Bézier segments —
    /// smooth curves that still pass exactly through every data point.
    private static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for index in 0..<(points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = index + 2 < points.count ? points[index + 2] : p2
            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        guard let lo = series.min(), let hi = series.max() else { return "no data" }
        let range = lo == hi
            ? "\(Self.trim(lo)) each"
            : "\(Self.trim(lo)) to \(Self.trim(hi))"
        return "\(series.count) values, \(range)"
    }

    private static func trim(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2f", d)
    }
}

#if DEBUG
#Preview("Bars") {
    VStack(spacing: 24) {
        SparklineView([12, 18, 9, 24, 16, 30, 22])
        SparklineView([12, 18, 9, 24, 16, 30, 22], style: .line, color: .orange)
        SparklineView([7, 7, 7, 7])                       // constant series
        SparklineView([42])                               // single sample
        SparklineView([])                                 // placeholder
    }
    .padding()
}
#endif
