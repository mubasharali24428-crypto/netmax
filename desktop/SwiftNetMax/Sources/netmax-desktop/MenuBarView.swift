import SwiftUI

/// Dashboard placeholder: run the engine's quick test, show status + results.
/// Honest-limits copy is a product requirement (README / C2), not decoration.
struct MenuBarView: View {
    @State private var client = EngineClient()
    @State private var status: RunStatus = .idle
    @State private var resultText: String = ""

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

            Divider()

            ScrollView {
                Text(resultText.isEmpty ? "No results yet." : resultText)
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
