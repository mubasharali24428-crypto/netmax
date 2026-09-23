// M9: mounted from RootView for first-run onboarding.

//
//  OnboardingScheduleHost.swift
//  netmax-desktop
//
//  ALPHA-A4-05 — Host wrapper appending the schedule opt-in (A1-10) to the
//  honest-limits onboarding without touching OnboardingView.swift.
//
//  Sequence, per A1-10's integration note:
//    1. Present OnboardingView unchanged (its own final Continue persists
//       "netmax.onboarding.complete", contract C2 / B1-shared key).
//    2. Intercept its `onComplete` — do NOT dismiss yet.
//    3. If `netmax.schedule.enabled` has never been written, show
//       OnboardingScheduleStep exactly once per run. Enable persists via
//       Scheduler.shared; Later persists nothing.
//    4. Fire the real completion (caller flips its AppStorage-backed flag
//       or dismisses the window here).
//
//  Drop-in replacement for direct OnboardingView usage: same single
//  trailing-closure shape (`OnboardingScheduleHost { ... }`). See the
//  INTEGRATION NOTE below for the RootView wiring lane.
//

import SwiftUI

/// Presents the four-step honest-limits onboarding followed by the optional
/// scheduled auto-tests opt-in, then reports completion.
///
/// Both child views size themselves identically (28pt padding, 460×320 min),
/// so hosting them in sequence needs no extra chrome. All persistence stays
/// inside the existing owners: OnboardingFlow (completion flag) and
/// `Scheduler.shared` (`netmax.schedule.*`) — this view never writes.
struct OnboardingScheduleHost: View {

    /// Which screen the host is showing.
    private enum Phase {
        /// The four honest-limits steps (OnboardingView).
        case onboarding
        /// Post-completion schedule opt-in (shown at most once per run).
        case scheduleOptIn
    }

    @State private var phase: Phase = .onboarding

    /// Fired after the last screen the user sees: right after the schedule
    /// step's Enable/Later, or immediately after onboarding completes when
    /// the step is skipped. At this point the completion flag is already
    /// persisted by OnboardingView itself.
    var onComplete: () -> Void = {}

    var body: some View {
        switch phase {
        case .onboarding:
            OnboardingView(onComplete: handleOnboardingComplete)
        case .scheduleOptIn:
            OnboardingScheduleStep(
                onEnable: finish,
                onLater: finish
            )
        }
    }

    // MARK: - Transitions

    /// OnboardingView's completion hook. Its final Continue has just
    /// persisted the shared flag; hold the dismissal and offer the schedule
    /// opt-in unless the user has already made a choice in an earlier run.
    private func handleOnboardingComplete() {
        guard !hasStoredSchedulePreference else {
            finish()
            return
        }
        phase = .scheduleOptIn   // shown exactly once per run
    }

    private func finish() {
        onComplete()
    }

    // MARK: - Preference probe

    /// Whether `netmax.schedule.enabled` was ever written.
    ///
    /// Read-only presence check against the exact key spelling from
    /// ScheduleKeys. `Scheduler`'s public surface cannot distinguish "unset"
    /// from "explicitly false" (its init falls back to
    /// `ScheduleFallbacks.enabled == false` either way), so the raw lookup is
    /// the only way to honor "only when unset". Writes stay with Scheduler;
    /// this path never touches UserDefaults setters.
    private var hasStoredSchedulePreference: Bool {
        UserDefaults.standard.object(forKey: ScheduleKeys.enabled) != nil
    }
}

// MARK: - INTEGRATION NOTE (RootView wiring lane)
//
// RootView currently hosts OnboardingView directly:
//
//     if onboardingComplete {
//         MainTabView()
//     } else {
//         OnboardingView {
//             onboardingComplete = true
//         }
//     }
//
// Swap the closure's owner — nothing else changes:
//
//     } else {
//         OnboardingScheduleHost {
//             // Runs AFTER the optional schedule step resolves (or
//             // immediately if it was skipped). "netmax.onboarding.complete"
//             // is already persisted at this point, so flipping this
//             // AppStorage-backed flag swaps in MainTabView.
//             onboardingComplete = true
//         }
//     }
//
// Why the wrapper exists: OnboardingView fires `onComplete` the instant its
// fourth Continue persists the flag, leaving no seam to interpose a step.
// The host owns that seam without editing the off-limits file, and the
// schedule step sits outside Contract C2's four-step count, so OnboardingView's
// "step x/4" progress display is unaffected.

#if DEBUG
struct OnboardingScheduleHost_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingScheduleHost()
    }
}
#endif
