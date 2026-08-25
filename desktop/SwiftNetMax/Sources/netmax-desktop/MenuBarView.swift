import SwiftUI

/// Menu bar dashboard: run the engine's quick test, show live metric cards
/// (adopted from DashboardCardsView — wave-3, ALPHA-A3-01), status + results.
/// Honest-limits copy is a product requirement (README / C2), not decoration.
struct MenuBarView: View {
    @State private var client = EngineClient()
    @State private var status: RunStatus = .idle
    @State private var resultText: String = ""
    @State private var historyRecords: [HistoryRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.blue)
                Text("NetMax")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            Button {
                runQuickTest()
            } label: {
                Label("Run Quick Test", systemImage: "play.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(status == .running)
            .accessibilityLabel("Run Quick Test")
            .accessibilityHint("Starts a short NetMax engine test and shows results below")

            // Wave-3 (ALPHA-A3-01): live metric cards beneath Quick Test,
            // above the results area. Hidden until history holds a first
            // record; refreshed on appear and after every successful run.
            if !historyRecords.isEmpty {
                dashboardSection
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
            .accessibilityLabel("Engine test results")
            .accessibilityValue(resultText.isEmpty ? "No results yet" : resultText)

            Spacer(minLength: 0)

            Text("Cannot exceed your ISP cap — gains appear only under contention.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380, height: 520)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(status.label)
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
                detail: m.statusWord == nil ? "run a test to assess" : "composite of latest results"
            )
            .netMaxHoverLift()
        }
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

    private func runQuickTest() {
        guard status != .running else { return }
        status = .running
        resultText = ""
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
                    resultText = "Error: \(error.localizedDescription)"
                    status = .error
                }
            }
        }
    }
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
