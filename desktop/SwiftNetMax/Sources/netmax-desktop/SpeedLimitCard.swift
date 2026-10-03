import SwiftUI

/// W17 — Dashboard Speed Limit (user-requested): a dedicated, highlighted
/// entry point for the engine's `limit` mode, visually separate from every
/// other dashboard feature. The red rectangular bar is solely the limit
/// feature's; tapping it opens the limit panel where any speed (0.5–10000
/// Mbps, decimals allowed) is held for a chosen duration.
///
/// Engine contract: `limit --mbps F --seconds N --streams K` (bridge
/// MODE_FLAGS + RANGE_BOUNDS mbps 0.5...10000). The engine runs a
/// closed-loop governor (netmax.py `_limit_governor`) that re-paces curl
/// every 5 s from measured progress, so the cap stays pinned over long
/// periods even as the line wobbles — and it reports a stability score.
struct SpeedLimitCard: View {
    @State private var expanded = false
    @State private var client = EngineClient()
    @State private var running = false
    @State private var stoppedByUser = false
    @State private var capText = "2"
    @State private var seconds = 1800
    @State private var streams = 1
    @State private var resultText = ""

    /// Red used across the card (button + panel accents) — user-specified.
    private static let limitRed = Color(red: 0.80, green: 0.15, blue: 0.15)

    /// Parsed cap in Mbps; nil while the text isn't a valid speed value.
    private var capMbps: Double? {
        Self.parseCapMbps(capText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            limitButton
            if expanded {
                limitPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: The red bar (rectangular, full-width, solely the limit feature)

    private var limitButton: some View {
        Button {
            withAnimation(NetMaxMotion.standard) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SPEED LIMIT")
                        .font(.headline)
                    Text("Hold one exact speed for a set time")
                        .font(.caption2)
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.limitRed)
            .cornerRadius(4)                       // rectangular, not capsule
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed limit mode")
        .accessibilityHint(expanded
            ? "Collapses the speed limit panel"
            : "Opens the panel to hold one exact network speed for a set period")
        .accessibilityAddTraits(expanded ? [.isSelected] : [])
    }

    // MARK: Limit panel

    private var limitPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            speedRow
            DurationEntryView(seconds: $seconds, isRunning: running)
            streamsRow

            HStack(spacing: 8) {
                Button {
                    startLimit()
                } label: {
                    Label(running ? "Limiting…" : "Start Limit",
                          systemImage: running ? "hourglass" : "lock.rotation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.limitRed)
                .controlSize(.large)
                .disabled(running || capMbps == nil)
                .accessibilityLabel(capMbps.map { "Start limit at \(SpeedLimitCard.formatMbps($0))" }
                                    ?? "Start limit — enter a valid speed first")

                if running {
                    StopRunButton(isRunning: true) { stoppedByUser = true }
                }
            }

            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Holding \(SpeedLimitCard.formatMbps(capMbps ?? 0)) — "
                         + "the speedometer below shows it live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Limit running")
            }

            if let cap = capMbps, !running, Self.parseCapMbps(capText) == nil {
                Text("Enter a speed between 0.5 and 10000 Mbps (decimals ok).")
                    .font(.caption2)
                    .foregroundStyle(Self.limitRed)
            }

            resultBox
        }
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Self.limitRed.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speed limit panel")
    }

    /// Free-form speed entry: any value 0.5–10000 Mbps, decimals allowed.
    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Speed")
                    .frame(width: 64, alignment: .leading)
                TextField("2", text: $capText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                    .monospacedDigit()
                    .disabled(running)
                    .accessibilityLabel("Speed cap value in Mbps")
                Text("Mbps")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(capCaption)
                .font(.caption2)
                .foregroundStyle(capMbps == nil ? Self.limitRed : Color.secondary)
        }
    }

    private var capCaption: String {
        capMbps.map { "0.5 – 10000 Mbps · engine will hold \(SpeedLimitCard.formatMbps($0)) for the whole run" }
            ?? "Enter a number between 0.5 and 10000"
    }

    private var streamsRow: some View {
        HStack(spacing: 10) {
            Text("Streams")
                .frame(width: 64, alignment: .leading)
            Stepper("\(streams)", value: $streams, in: 1...50)
                .labelsHidden()
                .disabled(running)
            Text("the cap is split across them — the total stays at your speed")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parallel streams")
        .accessibilityValue("\(streams)")
    }

    private var resultBox: some View {
        Group {
            if !resultText.isEmpty {
                ScrollView {
                    Text(resultText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .accessibilityLabel("Speed limit result")
                .accessibilityValue(resultText)
            }
        }
    }

    // MARK: Actions

    private func startLimit() {
        guard !running, let cap = capMbps else { return }
        running = true
        resultText = ""
        stoppedByUser = false
        // Snapshot at START (observed-live fix): the user can edit the panel
        // while a long hold runs — the engine args AND the history record
        // must describe the run as launched, not the panel at completion
        // (pre-fix, history showed 1500s params on a 30s run).
        let runCap = cap
        let runSeconds = seconds
        let runStreams = streams
        let args = ["--mbps", SpeedLimitCard.formatMbps(runCap),
                    "--seconds", "\(runSeconds)",
                    "--streams", "\(runStreams)"]
        Task {
            do {
                let output = try await client.run("limit", args: args)
                await MainActor.run {
                    resultText = output
                    running = false
                    // C4: land in history so cards/timeline/alerts refresh.
                    // mbps is stored Int-rounded (history params are Int);
                    // the exact value lives in the raw engine payload.
                    let record = HistoryStore.shared.append(
                        mode: "limit",
                        params: ["streams": runStreams, "seconds": runSeconds,
                                 "mbps": Int(runCap.rounded())],
                        raw: output)
                    RunPostProcessor.process(record)
                }
            } catch {
                await MainActor.run {
                    resultText = stoppedByUser
                        ? "Speed limit stopped."
                        : "Error: \(error.localizedDescription)"
                    stoppedByUser = false
                    running = false
                }
            }
        }
    }

    // MARK: Pure helpers (offline self-checked)

    /// "2" → 2.0, "2,5" → 2.5, "abc"/"0.4"/"10001" → nil.
    static func parseCapMbps(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), (0.5...10_000).contains(value) else {
            return nil
        }
        return value
    }

    /// Engine-flag formatting: "2" not "2.0", "2.5" stays "2.5".
    static func formatMbps(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))"
            : "\(value)"
    }
}

#if DEBUG
/// Offline self-checks (house runAll() harness convention — see ModeLabTests).
enum SpeedLimitCardTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[SpeedLimitCardTests] FAIL: \(name)") }
        }

        check(SpeedLimitCard.parseCapMbps("2") == 2.0, "plain integer parses")
        check(SpeedLimitCard.parseCapMbps("2.5") == 2.5, "decimal parses")
        check(SpeedLimitCard.parseCapMbps("2,5") == 2.5, "comma decimal parses")
        check(SpeedLimitCard.parseCapMbps(" 10 ") == 10.0, "whitespace trimmed")
        check(SpeedLimitCard.parseCapMbps("abc") == nil, "garbage rejected")
        check(SpeedLimitCard.parseCapMbps("") == nil, "empty rejected")
        check(SpeedLimitCard.parseCapMbps("0.4") == nil, "below floor rejected")
        check(SpeedLimitCard.parseCapMbps("10001") == nil, "above ceiling rejected")
        check(SpeedLimitCard.parseCapMbps("0.5") == 0.5, "floor accepted")
        check(SpeedLimitCard.parseCapMbps("10000") == 10_000.0, "ceiling accepted")

        check(SpeedLimitCard.formatMbps(2.0) == "2", "integral formats without .0")
        check(SpeedLimitCard.formatMbps(2.5) == "2.5", "decimal preserved")
        check(SpeedLimitCard.formatMbps(0.5) == "0.5", "floor formats")

        return failures
    }
}
#endif

#Preview("Speed Limit Card") {
    SpeedLimitCard()
        .padding()
}
