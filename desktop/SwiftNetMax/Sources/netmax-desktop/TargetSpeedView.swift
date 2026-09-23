import SwiftUI

/// W12-USER-IDEA — "Target speed" mode (user-requested).
///
/// The user states their plan cap once (Settings or right here). The app then
/// offers target speeds WITHIN that plan — e.g. a 10 Mbps plan offers
/// 2/4/6/8/10 Mbps targets — and computes how many parallel streams to open
/// to reach the chosen target honestly. If the measured result falls short of
/// the target, the app says so plainly (honest-limits brand: we can only use
/// what the connection gives us; opening more streams cannot create
/// bandwidth the plan doesn't have).
struct TargetSpeedView: View {
    /// Plan cap in Mbps as stated by the user.
    @AppStorage("netmax.plan.mbps") private var planMbps: Double = 100

    @State private var selectedTarget: Double?
    @State private var isRunning = false
    @State private var lastResult: String = ""
    let onRun: (_ streams: Int, _ seconds: Int, _ targetMbps: Double,
                _ finished: @escaping () -> Void) -> Void

    /// Target menu = sensible fractions of the plan, deduped and ≤ plan.
    private var targets: [Double] {
        let fractions: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0]
        let raw = fractions.map { max(1, ($0 * planMbps / 5).rounded() * 5) }
        return Array(Set(raw)).sorted()
    }

    /// Stream estimate: prefer the last measured run's throughput/stream;
    /// fall back to 6.0 Mbps when history is empty or unusable. Clamped to
    /// the engine's legal range (EngineParameterRanges.streams).
    private func streamsFor(target: Double) -> Int {
        let perStreamEstimate = Self.adaptivePerStreamEstimate()
        let needed = Int((target / perStreamEstimate).rounded(.up))
        return min(max(needed, 1), EngineParameterRanges.streams.upperBound)
    }

    /// L3: derive Mbps/stream from the most recent history record that has
    /// both a stream count and a parseable speed; nil-safe fallback 6.0.
    private static func adaptivePerStreamEstimate() -> Double {
        let fallback = 6.0
        guard let last = HistoryStore.shared.loadAll().last,
              let streams = last.params["streams"], streams > 0,
              let mbps = MetricExtractor.latestSpeedMbps(in: last.resultRaw),
              mbps > 0 else { return fallback }
        return max(1.0, mbps / Double(streams))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .foregroundStyle(Color.accentColor)
                Text("Target Speed")
                    .font(.headline)
                Spacer()
                Menu {
                    // W12 fix: inline plan editor — the old stub did nothing.
                    Section("Your plan speed") {
                        ForEach([5, 10, 20, 50, 100, 200, 500, 1000], id: \.self) { mbps in
                            Button {
                                planMbps = Double(mbps)
                            } label: {
                                if Int(planMbps) == mbps {
                                    Label(mbps >= 1000 ? "1 Gbps" : "\(mbps) Mbps",
                                          systemImage: "checkmark")
                                } else {
                                    Text(mbps >= 1000 ? "1 Gbps" : "\(mbps) Mbps")
                                }
                            }
                        }
                    }
                    Stepper {
                        Text("Custom: \(Int(planMbps)) Mbps")
                    } onIncrement: {
                        planMbps = min(planMbps + 5, 1000)
                    } onDecrement: {
                        planMbps = max(planMbps - 5, 5)
                    }
                } label: {
                    Text("Plan: \(Int(planMbps)) Mbps")
                        .font(.caption)
                }
                .accessibilityLabel(Text("Your internet plan speed — tap to change"))
            }

            Picker("Target", selection: $selectedTarget) {
                ForEach(targets, id: \.self) { t in
                    Text(formatMbps(t)).tag(Optional(t))
                }
            }
            .pickerStyle(.segmented)

            if let target = selectedTarget {
                HStack {
                    Text("Will open ~\(streamsFor(target: target)) parallel streams")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        isRunning = true
                        onRun(streamsFor(target: target), 10, target) {
                            isRunning = false
                        }
                    } label: {
                        Label("Reach \(formatMbps(target))",
                              systemImage: "arrow.up.forward.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }
                Text("If your line can't reach the target, NetMax will tell you plainly — it can't create bandwidth beyond what your ISP delivers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatMbps(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1f Gbps", v / 1000) : "\(Int(v)) Mbps"
    }
}
