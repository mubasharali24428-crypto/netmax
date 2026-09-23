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
    private var lastSample: (rx: UInt64, tx: UInt64, at: Date)?
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
            let now = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.lastSample = (rx, tx, now) }
                guard let prev = self.lastSample else { return } // first tick: baseline
                // Saturating subtract: interface counter can reset (ifdown/ifup);
                // UInt64 `rx - prev.rx` traps BEFORE max() runs.
                let dBytes = Self.saturatingDelta(rx, prev.rx)
                let uBytes = Self.saturatingDelta(tx, prev.tx)
                // Divide by ACTUAL elapsed seconds — a skipped/nil sample makes
                // the next delta span >1s; assuming 1.0 inflates the reading.
                let elapsed = now.timeIntervalSince(prev.at)
                guard elapsed > 0.05 else { return }
                let d = Double(dBytes) * 8 / elapsed / 1_000_000
                let u = Double(uBytes) * 8 / elapsed / 1_000_000
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
        return parseNetstatIBN(String(data: data, encoding: .utf8) ?? "")
    }

    /// Pure parser over `netstat -ibn` text: Link#-only sum.
    /// (Extraction for the offline selftest — see SpeedometerTests.)
    static func parseNetstatIBN(_ text: String) -> (rx: UInt64, tx: UInt64)? {
        var rx: UInt64 = 0, tx: UInt64 = 0, found = false
        for line in text.split(separator: "\n") {
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

    /// Saturating subtract for UInt64 byte counters (reset → 0, never traps).
    static func saturatingDelta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }

    /// Old (buggy) parser kept only for the selftest's inflation assertion.
    /// Sums EVERY en* row — IPv4/IPv6 duplicates count en0 5×.
    static func parseNetstatIBNAllRows(_ text: String) -> (rx: UInt64, tx: UInt64)? {
        var rx: UInt64 = 0, tx: UInt64 = 0, found = false
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ").map(String.init)
            guard cols.count >= 10, cols.first?.hasPrefix("en") == true else { continue }
            guard let r = UInt64(cols[6]), let t = UInt64(cols[9]) else { continue }
            rx += r; tx += t; found = true
        }
        return found ? (rx, tx) : nil
    }
}

/// Offline selftest: the gauge must not inflate when netstat repeats counters.
enum SpeedometerTests {
    /// Run all checks; returns number of failures (0 == pass).
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL"): \(name)")
            if !cond { failures += 1 }
        }

        // Synthetic fixture: en0 ×5 rows (Link + 2 IPv6 + IPv4) with IDENTICAL
        // counters, plus 6 idle Link# ifaces — matches live `netstat -ibn` on
        // this Mac (en0 is 5 rows → old parser = 5× inflation).
        let fixture = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        en4        1500  <Link#7>    3e:31:d2:5e:97:05        0     0          0        0     0          0     0
        en5        1500  <Link#8>    3e:31:d2:5e:97:06        0     0          0        0     0          0     0
        en6        1500  <Link#9>    3e:31:d2:5e:97:07        0     0          0        0     0          0     0
        en1        1500  <Link#10>   36:d4:1c:e5:bf:40        0     0          0        0     0          0     0
        en2        1500  <Link#11>   36:d4:1c:e5:bf:44        0     0          0        0     0          0     0
        en3        1500  <Link#12>   36:d4:1c:e5:bf:48        0     0          0        0     0          0     0
        en0        1500  <Link#14>   ba:23:43:ae:e4:12 44979151     0 56038715958 20595066     0 10502267056     0
        en0        1500  fe80::140a: fe80:e::140a:a3e: 44979151     - 56038715958 20595066     - 10502267056     -
        en0        1500  2402:ad80:1 2402:ad80:130:137 44979151     - 56038715958 20595066     - 10502267056     -
        en0        1500  2402:ad80:1 2402:ad80:130:137 44979151     - 56038715958 20595066     - 10502267056     -
        en0        1500  10.82.255/24  10.82.255.196   44979151     - 56038715958 20595066     - 10502267056     -
        """

        let link = ThroughputSampler.parseNetstatIBN(fixture)
        let all = ThroughputSampler.parseNetstatIBNAllRows(fixture)
        let en0Rx: UInt64 = 56_038_715_958

        check("parser returns a value", link != nil && all != nil)
        check("Link# parser counts en0 once", link?.rx == en0Rx)
        check("old all-row parser counts en0 5×", all?.rx == en0Rx * 5)
        if let l = link?.rx, let a = all?.rx, l > 0 {
            check("old parser inflates exactly 5× on this fixture", a == l * 5)
        } else {
            check("old parser inflates exactly 5× on this fixture", false)
        }

        // Empty / header-only → nil (no interfaces found).
        check("empty text → nil", ThroughputSampler.parseNetstatIBN("") == nil)
        check("header only → nil",
              ThroughputSampler.parseNetstatIBN("Name Mtu Network Address Ipkts\n") == nil)

        // Non-en interfaces ignored.
        let loOnly = "lo0 16384 <Link#1> 127.0.0.1 1 0 100 1 0 200 0\n"
        check("lo0 ignored", ThroughputSampler.parseNetstatIBN(loOnly) == nil)

        // Saturating subtract: counter reset must yield 0, not trap.
        check("counter reset → 0 delta (no UInt64 trap)",
              ThroughputSampler.saturatingDelta(10, 1000) == 0)
        check("normal delta",
              ThroughputSampler.saturatingDelta(1500, 1000) == 500)

        return failures
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
