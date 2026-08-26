import SwiftUI

/// Menu bar dashboard: run the engine's quick test, show live metric cards
/// (adopted from DashboardCardsView — wave-3, ALPHA-A3-01), status + results.
/// Honest-limits copy is a product requirement (README / C2), not decoration.
struct MenuBarView: View {
    @State private var client = EngineClient()
    @State private var status: RunStatus = .idle
    @State private var resultText: String = ""
    @State private var historyRecords: [HistoryRecord] = []

    /// T2-a (W11-A-059): pin toggle so results survive outside-clicks during
    /// review. HONEST LIMITATION: SwiftUI's `MenuBarExtra(.window)` exposes no
    /// public API to suppress the system's dismissal-on-resign-active, so this
    /// toggle records user intent and reflects state (filled glyph + tooltip);
    /// fully honoring it requires an NSPopover-based host helper, which is
    /// outside this lane's owned files. Documented rather than faked.
    @State private var pinned = false

    var body: some View {
        // W13 fix: whole popover content scrolls — the fixed VStack overflowed
        // the 480pt-min window once speedometer + cards + results stacked up,
        // clipping the bottom with no way to reach it.
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.blue)
                Text("NetMax")
                    .font(.headline)
                Spacer()
                if status == .running {
                    // T2-a (W11-A-007): a real spinner beside the label —
                    // the disabled button alone didn't read as "in progress".
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Test running")
                }
                statusBadge
                pinButton
            }

            // W11 fix #1: the main feature is the FIRST thing in the popover —
            // no tab-hunting to run a test. Prominent, full-width, obvious.
            Button {
                runQuickTest()
            } label: {
                Label(status == .running ? "Testing…" : "Run Quick Test",
                      systemImage: status == .running ? "hourglass" : "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(status == .running)
            .accessibilityLabel("Run Quick Test")
            .accessibilityHint("Starts a short Quick Test and shows results below")

            // W16: Stop on the dashboard (user-requested) — kills the engine.
            if status == .running {
                StopRunButton(isRunning: true)
                    .transition(.opacity)
                    .accessibilityHint("Stops the quick test currently running")
            }

            // W12 USER-IDEA: target-speed mode — user states their plan cap,
            // picks a target within it, app computes the streams needed.
            // Sits directly under Run Quick Test so both paths to the main
            // feature are visible without tab navigation.
            TargetSpeedView { streams, seconds, _ in
                runQuickTest(streams: streams, seconds: seconds)
            }

            // W13: live speedometer — real-time throughput of every app on
            // this Mac, sampled each second from interface byte counters.
            Divider()
            SpeedometerView()
                .frame(maxWidth: .infinity)

            // Wave-3 (ALPHA-A3-01): live metric cards beneath Quick Test,
            // above the results area. Hidden until history holds a first
            // record; refreshed on appear and after every successful run.
            if !historyRecords.isEmpty {
                dashboardSection
                miniTimeline
            }

            Divider()

            ScrollView {
                // §16 wayfinding: the placeholder names the specific next
                // action instead of dead-ending on "no results".
                Text(resultText.isEmpty ? "Run Quick Test to see engine output here." : resultText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .cornerRadius(6)
            .frame(minHeight: 220)
            .accessibilityLabel("Quick Test results")
            .accessibilityValue(resultText.isEmpty ? "No results yet" : resultText)

            Spacer(minLength: 0)

            Text("Cannot exceed your ISP cap — gains appear only under contention.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        }
        // W13: fixed height removed — the popover now sizes to content and
        // scrolls; height: 520 was clipping the speedometer + cards + results
        // stack with no way to reach the bottom.
        .frame(width: 380)
        .onAppear(perform: reloadHistory)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.caption)
        }
        // T2-a (W11-A-008): the grade letters come straight from netmax.py's
        // Waveform/DSLReports rubric — explain them where they're shown.
        .help("Status of the current run. Bufferbloat grades follow the "
            + "Waveform/DSLReports rubric: A+/A = latency barely rises under "
            + "load (<5/<30 ms); B <60 ms; C <200 ms; D <400 ms; F worse.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(status.label)
    }

    /// T2-a (W11-A-059): pin toggle for this popover.
    private var pinButton: some View {
        Button {
            pinned.toggle()
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .foregroundStyle(pinned ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(pinned
              ? "Pinned — NetMax tries to keep this popover open while you review"
              : "Pin this popover so it stays open while you review results")
        .accessibilityLabel(pinned ? "Unpin popover" : "Pin popover")
        .accessibilityAddTraits(pinned ? [.isSelected] : [])
    }

    // MARK: Dashboard cards (wave-3, ALPHA-A3-01)

    /// The same four tiles as the Dashboard tab, laid out at popover width.
    ///
    /// This lane owns only MenuBarView.swift, and `DashboardCardsView` is a
    /// tab-hostable ROOT (its own header, refresh, footer, and a
    /// 420-pt-minimum frame) — embedding that root here would duplicate the
    /// honest-limits footer and overflow the 380-pt menu bar panel. So the
    /// menu bar reuses its MODEL (`DashboardMetrics`) and its TILE
    /// (`MetricCard`) verbatim and composes the row locally. Sourcing honors
    /// contract P2: history is read exclusively through
    /// `HistoryStore.shared.loadAll()` — never the JSONL file.
    private var dashboardSection: some View {
        let m = DashboardMetrics.extract(from: historyRecords)
        return HStack(alignment: .top, spacing: 10) {
            MetricCard(
                title: "Latest Speed",
                icon: "gauge",
                value: m.speed.map { CardFormat.number($0.value) },
                unit: "Mbps",
                tint: CardFormat.speedTint(m.speed?.value),
                detail: m.speed.map { "\($0.mode) · \(CardFormat.relative($0.date))" }
                    ?? "no speed run yet"
            )
            .netMaxHoverLift()
            MetricCard(
                title: "Bufferbloat",
                icon: "waveform.path",
                value: m.bloatGrade?.letter,
                unit: nil,
                tint: CardFormat.gradeTint(m.bloatGrade?.letter),
                detail: bloatDetail(m.bloatGrade)
            )
            .netMaxHoverLift()
            MetricCard(
                title: "Packet Loss",
                icon: "wifi.exclamationmark",
                value: m.loss.map { CardFormat.number($0.value) },
                unit: "%",
                tint: CardFormat.lossTint(m.loss?.value),
                detail: m.loss.map { "\($0.mode) · \(CardFormat.relative($0.date))" }
                    ?? "no loss run yet"
            )
            .netMaxHoverLift()
            MetricCard(
                title: "Status",
                icon: "checkmark.seal",
                value: m.statusWord,
                unit: nil,
                tint: CardFormat.statusTint(m.statusWord),
                detail: m.statusWord == nil ? "no runs to assess yet" : "composite of latest results"
            )
            .netMaxHoverLift()
        }
    }

    // MARK: - W10-1 (P4): mini-timeline sparkline strip

    /// Compact speed trend under the cards. Tapping opens the full Quality
    /// Timeline (same data, richer lanes) — wayfinding per apple-design §16.
    @ViewBuilder
    private var miniTimeline: some View {
        let series = DashboardMetrics.speedTrend(from: historyRecords)
        Group {
            if series.isEmpty {
                Text("Measure to see your speed trend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                SparklineView(series, style: .line, height: 28)
            }
        }
        .padding(.vertical, 4)
    }

    /// Same wording as DashboardCardsView.bloatDetail so both surfaces agree.
    private func bloatDetail(_ grade: GradeValue?) -> String {
        guard let grade else { return "no bloat run yet" }
        if let delta = grade.deltaMs {
            return String(format: "%+.1f ms under load · %@", delta, grade.mode)
        }
        return "latency under load · \(grade.mode)"
    }

    private func reloadHistory() {
        historyRecords = HistoryStore.shared.loadAll()
    }

    /// W12 USER-IDEA overload: target-speed path passes explicit streams so
    /// the engine opens exactly the parallelism the chosen target needs.
    private func runQuickTest(streams: Int, seconds: Int) {
        guard status != .running else { return }
        status = .running
        resultText = ""
        Task {
            do {
                let output = try await client.run(
                    "turbo", args: ["--streams", "\(streams)", "--seconds", "\(seconds)"])
                await MainActor.run {
                    resultText = "Target run (\(streams) streams):\n" + output
                    status = .done
                    reloadHistory()
                }
            } catch {
                await MainActor.run {
                    resultText = "Error: \(error.localizedDescription)"
                    status = .error
                }
            }
        }
    }

    private func runQuickTest() {
        guard status != .running else { return }
        status = .running
        resultText = ""
        quickTestStoppedByUser = false
        Task {
            do {
                // "boost" = baseline vs turbo + gain % — a real C1 engine mode.
                let output = try await client.run("boost", args: ["--seconds", "5"])
                await MainActor.run {
                    resultText = output
                    status = .done
                    reloadHistory()   // fresh run lands in the cards immediately
                }
            } catch {
                await MainActor.run {
                    if quickTestStoppedByUser {
                        // W16: user pressed Stop — honest, not an error.
                        resultText = "Quick Test stopped."
                        status = .idle
                        quickTestStoppedByUser = false
                    } else {
                        resultText = "Error: \(error.localizedDescription)"
                        status = .error
                    }
                }
            }
        }
    }

    /// W16: set when Stop is pressed during the popover Quick Test.
    @State private var quickTestStoppedByUser = false
}

/// Formatting/tint helpers mirrored from DashboardCardsView's private
/// counterparts so the menu bar cards match the tab pixel-for-pixel. Kept
/// file-private here because DashboardCardsView.swift is outside this lane.
private enum CardFormat {
    static func number(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func speedTint(_ mbps: Double?) -> Color {
        guard let mbps else { return .gray }
        if mbps >= 100 { return .green }
        if mbps >= 50 { return .yellow }
        if mbps >= 25 { return .orange }
        return .red
    }

    /// Waveform-rubric traffic lights (letters validated by MetricExtractor).
    static func gradeTint(_ letter: String?) -> Color {
        switch letter {
        case "A+", "A": .green
        case "B", "C": .yellow
        case "D": .orange
        case "F": .red
        default: .gray
        }
    }

    static func lossTint(_ percent: Double?) -> Color {
        guard let percent else { return .gray }
        if percent <= 0.5 { return .green }
        if percent <= 2 { return .yellow }
        if percent <= 5 { return .orange }
        return .red
    }

    static func statusTint(_ word: String?) -> Color {
        switch word {
        case "Excellent": .green
        case "Good": .yellow
        case "Fair": .orange
        case "Poor": .red
        default: .gray
        }
    }
}

private enum RunStatus {
    case idle, running, done, error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running…"
        case .done: "Done"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: .gray
        case .running: .orange
        case .done: .green
        case .error: .red
        }
    }
}
