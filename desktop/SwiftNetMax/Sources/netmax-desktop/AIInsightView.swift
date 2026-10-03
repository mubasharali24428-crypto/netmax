import SwiftUI

/// Drives one AI analysis at a time on behalf of `AIInsightCard`.
@MainActor
final class AIInsightModel: ObservableObject {

    enum State {
        case idle
        case running(String)          // analysis name
        case done(name: String, result: [String: Any])
        case failed(name: String, message: String)
    }

    @Published private(set) var state: State = .idle

    private let client: EngineClient

    init(client: EngineClient = EngineClient()) {
        self.client = client
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Run an analysis over a metrics bundle. `input` is whatever the
    /// surrounding view has measured — the catalogue decides what it needs.
    func run(_ entry: AIAnalysis.Entry, input: [String: Any]) async {
        state = .running(entry.name)
        do {
            let result = try await AIAnalysis.run(entry, input: input, client: client)
            state = .done(name: entry.name, result: result)
        } catch {
            state = .failed(name: entry.name,
                            message: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription)
        }
    }
}

/// One analysis, described and run from the measurements on hand.
struct AIInsightCard: View {
    let entry: AIAnalysis.Entry
    /// Metrics bundle from the latest run.
    let input: [String: Any]
    var client: EngineClient = EngineClient()

    @StateObject private var model: AIInsightModel

    init(entry: AIAnalysis.Entry, input: [String: Any], client: EngineClient = EngineClient()) {
        self.entry = entry
        self.input = input
        self.client = client
        _model = StateObject(wrappedValue: AIInsightModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header

            switch model.state {
            case .idle:
                Text("Not run yet.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)

            case .running:
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Analysing…")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                }

            case .failed(_, let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.gradeD)

            case .done(_, let result):
                resultBody(result)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.title)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.headline)
                Text(entry.blurb)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: Theme.Spacing.sm)
            Button {
                Task { await model.run(entry, input: input) }
            } label: {
                Image(systemName: model.isRunning ? "hourglass" : "sparkles")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRunning)
            .help("Run this analysis")
            .accessibilityLabel("Run \(entry.title)")
        }
    }

    @ViewBuilder
    private func resultBody(_ result: [String: Any]) -> some View {
        if let headline = AIAnalysis.headline(result) {
            Text(headline)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }

        if AIAnalysis.isInconclusive(result) {
            Label("Not enough data to conclude — run more measurements first.",
                  systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }

        let causes = AIAnalysis.causes(result)
        ForEach(Array(causes.enumerated()), id: \.offset) { pair in
            causeRow(pair.element)
        }

        let bullets = AIAnalysis.bullets(result)
        if !bullets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(bullets.prefix(6).enumerated()), id: \.offset) { pair in
                    if let line = pair.element as? String {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                            Text("•")
                                .foregroundStyle(Theme.secondaryText)
                            Text(line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                    }
                }
            }
        }

        let caveats = AIAnalysis.caveats(result)
        if !caveats.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(caveats.prefix(4).enumerated()), id: \.offset) { pair in
                    if let line = pair.element as? String {
                        Label(line, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.gradeC)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        // Provenance: a local-heuristic answer and a model answer are not
        // the same claim, and the user should be able to tell them apart.
        Text(AIAnalysis.source(result) == "ai"
             ? "Answered by the model · local checks ran first"
             : "Answered locally · no API key needed")
            .font(.caption2)
            .foregroundStyle(Theme.secondaryText)
    }

    private func causeRow(_ cause: [String: Any]) -> some View {
        let severity = (cause["severity"] as? String) ?? "low"
        let tint = Theme.severityColor(severity)
        return HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text((cause["cause"] as? String) ?? "unknown")
                    .font(.callout.weight(.medium))
                ForEach(Array(((cause["evidence"] as? [Any]) ?? []).prefix(2).enumerated()),
                        id: \.offset) { pair in
                    if let text = pair.element as? String {
                        Text(text).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                ForEach(Array(((cause["fixes"] as? [Any]) ?? []).prefix(2).enumerated()),
                        id: \.offset) { pair in
                    if let text = pair.element as? String {
                        Text("→ " + text).font(.caption)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The AI section: one card per catalogue entry, fed the latest metrics.
struct AIInsightSection: View {
    /// Metrics bundle from the most recent run.
    let input: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Insight")
                .font(.title3.weight(.semibold))
            Text("Each card reads the measurements already on screen. Nothing "
                 + "here changes your network.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)

            ForEach(AIAnalysis.catalogue) { entry in
                AIInsightCard(entry: entry, input: input)
            }
        }
    }
}