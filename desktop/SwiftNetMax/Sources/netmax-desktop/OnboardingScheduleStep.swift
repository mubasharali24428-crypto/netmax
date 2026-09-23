// AUDIT M9: not mounted in production — wire or remove deliberately.

//
//  OnboardingScheduleStep.swift
//  netmax-desktop
//
//  ALPHA-A1-10 — Optional 5th onboarding step: scheduled auto-tests opt-in.
//
//  INTEGRATION NOTE (for the onboarding coordinator — this file is a
//  standalone view; nothing else references it yet):
//
//    The flow in OnboardingFlow.swift is fixed at four steps (Contract C2,
//    `DefaultOnboardingFlow.totalSteps = 4`) and must NOT be edited here.
//    To append this step later, the coordinator should present it after the
//    fourth step's Continue (i.e. when `flow.isComplete` first turns true)
//    but BEFORE dismissing the window / calling the completion persist:
//
//        if flow.isComplete && !scheduleStepShown {
//            scheduleStepShown = true          // show exactly once per run
//            OnboardingScheduleStep(
//                onEnable: { /* continue to DefaultOnboardingFlow.setCompleted(true) */ },
//                onLater:  { /* same completion path as above */ }
//            )
//        }
//
//    Both buttons terminate this step; "Later" simply skips without writing.
//    Because this step sits outside Contract C2's four-step count, it never
//    affects the "step x/4" ProgressView shown by OnboardingView.
//
//  Persistence: delegated entirely to `Scheduler.shared` (ALPHA-A1-01),
//  which owns the `netmax.schedule.*` keys (`enabled`, `intervalMinutes`)
//  and their clamping (5...1440, default 60). This view never touches
//  UserDefaults directly, per the contract stated in Scheduler.swift.
//

import SwiftUI

/// Optional fifth onboarding step: "Run tests automatically every N minutes?"
///
/// Styled to match the existing honest-limits steps (OnboardingView.swift):
/// leading-aligned title2/semibold headline over body copy, system semantic
/// colors only, `.borderedProminent` primary action, full keyboard and
/// VoiceOver support with stable accessibility identifiers.
struct OnboardingScheduleStep: View {
    /// Chosen cadence in minutes; kept inside `ScheduleLimits.intervalMinutes`
    /// so `Scheduler` never has to re-clamp what we hand it. Previews/tests
    /// may inject an initial value.
    @State private var intervalMinutes: Int

    /// User accepted scheduling — enables the shared scheduler at the chosen
    /// cadence (persisting `netmax.schedule.enabled` + `intervalMinutes`),
    /// then reports completion.
    var onEnable: () -> Void = {}

    /// User deferred ("Later") — persists nothing, just reports completion.
    var onLater: () -> Void = {}

    init(intervalMinutes: Int = ScheduleFallbacks.intervalMinutes,
         onEnable: @escaping () -> Void = {},
         onLater: @escaping () -> Void = {}) {
        _intervalMinutes = State(initialValue: ScheduleConfig.clampedInterval(intervalMinutes))
        self.onEnable = onEnable
        self.onLater = onLater
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep an eye on your connection")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.primary)

                Text("NetMax can run a quick test automatically so your history stays current — even when you forget.")
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You can change or turn this off anytime in Settings.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            intervalPicker

            Spacer(minLength: 8)
            controls
        }
        .padding(28)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 380)
        .accessibilityIdentifier("onboarding.schedule")
    }

    // MARK: - Interval picker

    private var intervalPicker: some View {
        HStack(spacing: 10) {
            Stepper(
                value: $intervalMinutes,
                in: ScheduleLimits.intervalMinutes,
                step: 5
            ) {
                Text("Every \(intervalMinutes) min")
            }
            .accessibilityLabel(Text("Test interval in minutes"))
            .accessibilityValue(Text("\(intervalMinutes) minutes"))
            .accessibilityIdentifier("onboarding.schedule.stepper")

            Spacer()
        }
    }

    // MARK: - Actions row

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                onLater()
            } label: {
                Text("Later").frame(minWidth: 88)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Later"))
            .accessibilityHint(Text("Skips scheduling; nothing is changed. You can enable it later in Settings."))
            .accessibilityIdentifier("onboarding.schedule.later")

            Spacer()

            Button {
                enableTapped()
            } label: {
                Text("Enable").frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text("Enable"))
            .accessibilityHint(Text("Runs a test automatically every \(intervalMinutes) minutes."))
            .accessibilityIdentifier("onboarding.schedule.enable")
        }
    }

    // MARK: - Persistence (via the schedule lane's facade)

    private func enableTapped() {
        let scheduler = Scheduler.shared          // main thread per its contract
        scheduler.intervalMinutes = intervalMinutes // clamped + persisted by didSet
        scheduler.isEnabled = true                  // persisted by didSet
        onEnable()
    }
}

#if DEBUG
struct OnboardingScheduleStep_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            OnboardingScheduleStep()
            OnboardingScheduleStep(intervalMinutes: 30)
        }
    }
}
#endif
