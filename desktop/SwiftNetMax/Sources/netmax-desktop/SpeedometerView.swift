import SwiftUI

/// W13 — Real-time speedometer: live device throughput (down + up) drawn as
/// a car-style gauge, updated every second.
///
/// Data source: `netstat -ibn` byte counters on the primary interface,
/// sampled once per second and diffed. This measures REAL total traffic of
/// the Mac — every app, every download — not a synthetic test. Honest-limits
/// note in footer: it shows what the connection is carrying right now, not
/// the maximum it could carry.
struct SpeedometerView: View {
    @State private var downMbps: Double = 0
    @State private var upMbps: Double = 0
    @State private var peakDownMbps: Double = 0
    @State private var timer: Timer?

    // Gauge scale: dynamic top so small plans aren't pinned at zero and
    // gigabit lines aren't pegged at max. Grows to fit observed peaks.
    private var gaugeMax: Double { max(100, nextNice(peakDownMbps * 1.2)) }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                // Track arc
                GaugeArc(trim: 1.0)
                    .stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .foregroundStyle(.secondary.opacity(0.25))
                // Value arc (download)
                GaugeArc(trim: fraction(downMbps, gaugeMax))
                    .stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .foregroundStyle(Color.accentColor)
                    .animation(.spring(response: 0.5, dampingFraction: 1.0), value: downMbps)

                VStack(spacing: 2) {
                    Text(downMbps >= 100 ? "\(Int(downMbps))" : String(format: "%.1f", downMbps))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .kerning(-1)
                        .monospacedDigit()
                    Text("Mbps down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 130)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live download speed: \(Text("\(Int(downMbps))")) megabits per second")

            HStack(spacing: 20) {
                Label {
                    Text("↑ \(format(upMbps)) Mbps")
                        .font(.callout.weight(.medium))
                        .accessibilityLabel("Upload: \(Int(upMbps)) megabits per second")
                } icon: {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.secondary)
                }
                Label {
                    Text("Peak \(format(peakDownMbps))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Live traffic from every app on this Mac — sampled each second.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    // MARK: - Sampling

    private func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in sample() }
        sample()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Diffs `netstat -ibn` interface byte counters over one second.
    /// Runs on a background queue; UI updates hop back to main.
    private func sample() {
        DispatchQueue.global(qos: .utility).async {
            let (rx, tx) = Self.interfaceBytes()
            guard let rxB = rx, let txB = tx else { return }
            Thread.sleep(forTimeInterval: 1.0)
            let (rx2, tx2) = Self.interfaceBytes()
            guard let rx2 = rx2, let tx2 = tx2 else { return }
            let dMbps = Double(max(rx2 - rxB, 0)) * 8 / 1_000_000
            let uMbps = Double(max(tx2 - txB, 0)) * 8 / 1_000_000
            DispatchQueue.main.async {
                downMbps = dMbps
                upMbps = uMbps
                peakDownMbps = max(peakDownMbps, dMbps)
            }
        }
    }

    /// Sum of RX/TX bytes across active non-loopback interfaces.
    static func interfaceBytes() -> (rx: UInt64?, tx: UInt64?) {
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        out.arguments = ["-ibn"]
        let pipe = Pipe(); out.standardOutput = pipe; out.standardError = Pipe()
        do { try out.run() } catch { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        out.waitUntilExit()

        var rx: UInt64 = 0, tx: UInt64 = 0, found = false
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            let cols = line.split(separator: " ").map(String.init)
            guard cols.first?.hasPrefix("en") == true else { continue }
            // netstat -ibn columns: name mtu network address Ipkts Ierrs Ibytes Opkts Oerrs Obytes ...
            if cols.count >= 10, let r = UInt64(cols[6]), let t = UInt64(cols[9]) {
                rx += r; tx += t; found = true
            }
        }
        return found ? (rx, tx) : (nil, nil)
    }

    // MARK: - Helpers

    private func fraction(_ value: Double, _ max: Double) -> CGFloat {
        max == 0 ? 0 : CGFloat(min(value / max, 1.0))
    }

    private func nextNice(_ v: Double) -> Double {
        let steps: [Double] = [100, 250, 500, 1000, 2500, 5000, 10_000]
        return steps.first(where: { $0 >= v }) ?? (v.rounded(.up) / 1000 * 1000 + 5000)
    }

    private func format(_ v: Double) -> String {
        v >= 100 ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

/// Arc shape sweeping ~270° like a car dash gauge (gap at the bottom).
struct GaugeArc: Shape {
    let trim: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                 radius: min(rect.width, rect.height) / 2 - 8,
                 startAngle: .degrees(135),
                 endAngle: .degrees(405),
                 clockwise: false)
        return p.trimmedPath(from: 0, to: trim)
    }
}
