import SwiftUI

/// W13 — Real-time speedometer: live device throughput (down + up) drawn as
/// a car-style gauge, updated every second.
///
/// FIX (user report + audit follow-up, 2026-09-08): two bugs made the dial
/// lie and stay flat during runs:
///   1. ACCURACY — `netstat -ibn` prints ONE ROW PER ADDRESS FAMILY per
///      interface (`<Link#14>`, IPv6, IPv4) with IDENTICAL counters. The
///      old parser summed every row, tripling en0's traffic. Fix: parse
///      only `<Link#N>` rows (exactly one per interface).
///   2. LIFETIME — sampling was @State inside the view, which only lives
///      while its tab is selected: a Mode Lab run finished with the dial
///      never sampling (Dashboard tab dead), and switching back reset the
///      baseline to zero. Fix: `ThroughputSampler.shared` ticks for the
///      whole app lifetime, so the dial shows a run's traffic on any tab,
///      and the peak survives tab switches.
/// This still measures REAL total traffic of the Mac — every app, every
/// download — not a synthetic test.

/// App-lifetime throughput sampler: 1 netstat/tick, published to all views.
final class ThroughputSampler: ObservableObject {
    static let shared = ThroughputSampler()

    @Published var downMbps: Double = 0
    @Published var upMbps: Double = 0
    @Published var peakDownMbps: Double = 0

    private var timer: Timer?
    private var lastSample: (rx: UInt64, tx: UInt64)?
    private var tickCount = 0

    private init() {
        // F17 kept: ONE netstat invocation per tick (was 2).
        // .common mode (same lesson as ScheduleRunner.swift:16-19): a menu-
        // bar accessory app pumps timers in .default mode only while NOT
        // tracking; .common keeps the dial alive during popover tracking.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        sample()
    }

    private func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let bytes = Self.interfaceBytes() else { return }
            let (rx, tx) = bytes
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.lastSample = (rx, tx) }
                guard let prev = self.lastSample else { return } // first tick: baseline
                let d = Double(max(rx - prev.rx, 0)) * 8 / 1_000_000
                let u = Double(max(tx - prev.tx, 0)) * 8 / 1_000_000
                self.tickCount += 1
                // Slew the displayed value: a single 1s delta is spiky for
                // a gauge needle; blend 50% previous + 50% current for a
                // readable needle that still tracks real traffic closely.
                self.downMbps = self.tickCount < 3 ? d : (self.downMbps + d) / 2
                self.upMbps = self.tickCount < 3 ? u : (self.upMbps + u) / 2
                self.peakDownMbps = max(self.peakDownMbps, d)
            }
        }
    }

    /// Sum of RX/TX bytes across active interfaces — counting ONLY the
    /// `<Link#N>` row per interface (one row = one interface = counted once).
    static func interfaceBytes() -> (rx: UInt64, tx: UInt64)? {
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        out.arguments = ["-ibn"]
        let pipe = Pipe(); out.standardOutput = pipe; out.standardError = Pipe()
        do { try out.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        out.waitUntilExit()

        var rx: UInt64 = 0, tx: UInt64 = 0, found = false
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            let cols = line.split(separator: " ").map(String.init)
            // LINK-ROW-ONLY FIX: `<Link#N>` rows are one-per-interface;
            // IPv4/IPv6 rows repeat the same counters.
            guard cols.count >= 10,
                  cols.first?.hasPrefix("en") == true,
                  cols[2].hasPrefix("<Link#")
            else { continue }
            // netstat -ibn Link-row columns:
            //   name mtu <Link#N> address Ipkts Ierrs Ibytes Opkts Oerrs Obytes
            guard let r = UInt64(cols[6]), let t = UInt64(cols[9]) else { continue }
            rx += r; tx += t; found = true
        }
        return found ? (rx, tx) : nil
    }
}

struct SpeedometerView: View {
    @ObservedObject private var sampler = ThroughputSampler.shared

    // Gauge scale: dynamic top so small plans aren't pinned at zero and
    // gigabit lines aren't pegged at max. Grows to fit observed peaks.
    private var gaugeMax: Double { max(100, nextNice(sampler.peakDownMbps * 1.2)) }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                GaugeArc(trim: 1.0)
                    .stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .foregroundStyle(.secondary.opacity(0.25))
                GaugeArc(trim: fraction(sampler.downMbps, gaugeMax))
                    .stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .foregroundStyle(Color.accentColor)
                    .animation(.spring(response: 0.5, dampingFraction: 1.0), value: sampler.downMbps)

                VStack(spacing: 2) {
                    Text(sampler.downMbps >= 100 ? "\(Int(sampler.downMbps))" : String(format: "%.1f", sampler.downMbps))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .kerning(-1)
                        .monospacedDigit()
                    Text("Mbps down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 130)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live download speed: \(Text("\(Int(sampler.downMbps))")) megabits per second")

            HStack(spacing: 20) {
                Label {
                    Text("↑ \(format(sampler.upMbps)) Mbps")
                        .font(.callout.weight(.medium))
                        .accessibilityLabel("Upload: \(Int(sampler.upMbps)) megabits per second")
                } icon: {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.secondary)
                }
                Label {
                    Text("Peak \(format(sampler.peakDownMbps))")
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
        // NOTE: no onAppear/onDisappear lifecycle — the shared sampler runs
        // app-lifetime, so the dial shows traffic during any tab's run.
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
