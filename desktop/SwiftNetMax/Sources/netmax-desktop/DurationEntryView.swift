import SwiftUI

/// W15 — editable duration entry for Mode Lab (user-reported: steppers alone
/// made reaching "10 minutes" require dozens of clicks, and there was no
/// minutes/hours choice at all).
///
/// Replaces the plain seconds stepper row with:
///   • Unit segmented picker: Seconds / Minutes / Hours
///   • Direct text field — type 10, hit Enter, done
///   • Stepper retained for small adjustments
///
/// Internally everything stays in engine seconds (5…3600 clamp). The bridge
/// passes --seconds; long runs are legal because the engine streams data the
/// whole time. Range law: 5 s minimum, 6 h maximum.
struct DurationEntryView: View {
    @Binding var seconds: Int
    let isRunning: Bool

    enum DurationUnit: String, CaseIterable {
        case seconds = "sec"
        case minutes = "min"
        case hours = "hr"

        var multiplier: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            }
        }
    }

    @State private var unit: DurationUnit = .seconds
    /// The text being typed; commits to `seconds` on Enter/focus-loss if valid.
    @State private var draftText: String = ""
    @State private var invalidFlash = false

    private var displayValue: Int {
        seconds / unit.multiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Duration")
                    .frame(width: 70, alignment: .leading)

                TextField("value", text: $draftText, onCommit: commitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .monospacedDigit()
                    .disabled(isRunning)
                    .accessibilityLabel("Duration value")

                Picker("Unit", selection: $unit) {
                    ForEach(DurationUnit.allCases, id: \.self) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .disabled(isRunning)
                .accessibilityLabel("Duration unit")

                Spacer()

                Stepper {
                    Text("Adjust") // label hidden below
                } onIncrement: {
                    step(+1)
                } onDecrement: {
                    step(-1)
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
        .onAppear { syncDraftFromSeconds() }
        .onChange(of: unit) { _ in
            // Keep the displayed number sensible when the unit changes:
            // 90 s becomes 2 min (rounded), not 1 min 30 s in a seconds field.
            syncDraftFromSeconds()
        }
        .onChange(of: seconds) { _ in syncDraftFromSeconds() }
    }

    private var rangeAndEffectiveCaption: String {
        if invalidFlash {
            return "Enter a number — duration clamps to 5 seconds…6 hours."
        }
        return "Range: 5 sec … 6 hours · engine runs \(seconds) s"
    }

    // MARK: Conversion + validation

    private func syncDraftFromSeconds() {
        let v = Double(seconds) / Double(unit.multiplier)
        draftText = v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    private func commitText() {
        guard let typed = Double(draftText.trimmingCharacters(in: .whitespaces)),
              typed > 0 else {
            flashInvalid(); syncDraftFromSeconds(); return
        }
        let totalSeconds = Int((typed * Double(unit.multiplier)).rounded())
        applyClamped(totalSeconds)
    }

    private func step(_ direction: Int) {
        // Step in the current unit's natural increment: 10 s, 1 min, or ¼ h.
        let stepSeconds: Int
        switch unit {
        case .seconds: stepSeconds = 10 * direction
        case .minutes: stepSeconds = 60 * direction
        case .hours:   stepSeconds = 900 * direction
        }
        applyClamped(seconds + stepSeconds)
    }

    private func applyClamped(_ raw: Int) {
        let range = EngineParameterRanges.seconds // 5 s … 6 h (M3 SSOT)
        guard raw >= range.lowerBound else { flashInvalid(); syncDraftFromSeconds(); return }
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        seconds = clamped
        invalidFlash = false
    }

    private func flashInvalid() {
        invalidFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            invalidFlash = false
        }
    }
}
