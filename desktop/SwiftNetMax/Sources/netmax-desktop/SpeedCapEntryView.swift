import SwiftUI

/// Speed-cap entry for the Mode Lab `limit` mode (user-requested: hold a
/// chosen Mbps rate for the whole run — e.g. 2 Mbps for 30 minutes — no
/// matter how many streams are open).
///
/// Mirrors DurationEntryView's structure: direct text field (a 1-step
/// Stepper needed dozens of clicks to go 10 → 2), invalid flash, and a
/// range caption. Internally an Int Mbps value clamped to
/// `EngineParameterRanges.mbps` (1…10000; the engine/bridge accept 0.5+
/// fractional caps from the CLI).
struct SpeedCapEntryView: View {
    @Binding var mbps: Int
    let isRunning: Bool

    @State private var draftText: String = ""
    @State private var invalidFlash = false

    private var range: ClosedRange<Int> { EngineParameterRanges.mbps }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Speed cap")
                    .frame(width: 70, alignment: .leading)

                TextField("value", text: $draftText, onCommit: commitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .monospacedDigit()
                    .disabled(isRunning)
                    .accessibilityLabel("Speed cap value")

                Text("Mbps")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Spacer()

                Stepper {
                    Text("Adjust") // label hidden below
                } onIncrement: {
                    applyClamped(mbps + 1)
                } onDecrement: {
                    applyClamped(mbps - 1)
                }
                .labelsHidden()
                .disabled(isRunning)
            }

            HStack(spacing: 12) {
                Text(rangeAndEffectiveCaption)
                    .font(.caption2)
                    .foregroundStyle(invalidFlash ? Color.red : Color.secondary)
                Spacer()
            }
        }
        .onAppear { syncDraftFromMbps() }
        .onChange(of: mbps) { _ in syncDraftFromMbps() }
    }

    private var rangeAndEffectiveCaption: String {
        if invalidFlash {
            return "Enter a number — cap clamps to \(range.lowerBound)…\(range.upperBound) Mbps."
        }
        return "Range: \(range.lowerBound)–\(range.upperBound) Mbps · engine holds \(mbps) Mbps for the whole run"
    }

    // MARK: Conversion + validation

    private func syncDraftFromMbps() {
        draftText = "\(mbps)"
    }

    private func commitText() {
        guard let typed = Int(draftText.trimmingCharacters(in: .whitespaces)) else {
            flashInvalid(); syncDraftFromMbps(); return
        }
        applyClamped(typed)
    }

    private func applyClamped(_ raw: Int) {
        guard raw >= range.lowerBound, raw <= range.upperBound else {
            flashInvalid(); syncDraftFromMbps(); return
        }
        mbps = raw
        invalidFlash = false
    }

    private func flashInvalid() {
        invalidFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            invalidFlash = false
        }
    }
}

#Preview("Speed Cap Entry") {
    SpeedCapEntryView(mbps: .constant(2), isRunning: false)
        .padding()
}
