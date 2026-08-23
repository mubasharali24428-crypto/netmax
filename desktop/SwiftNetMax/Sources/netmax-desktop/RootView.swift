//
//  RootView.swift
//  netmax-desktop
//
//  L2-C1 — First-run gate: honest-limits onboarding (C2, B3's flow/view)
//  hosted inside the menu-bar window before handing over to the dashboard.
//

import SwiftUI

/// Single-window root for the MenuBarExtra shell.
///
/// Launch behavior: if the shared completion flag
/// (`OnboardingConstants.completionKey`, written by
/// `DefaultOnboardingFlow.setCompleted(_:)`) is absent/false — first run —
/// the honest-limits `OnboardingView` is presented; otherwise (or as soon as
/// onboarding completes) the `MenuBarView` dashboard shows.
///
/// Everything renders in the SAME MenuBarExtra window — no second scene,
/// sheet, or window. Each branch keeps its natural fit: the dashboard's
/// 380×520 and the onboarding flow's ideal 520×380 (OnboardingView declares
/// accessibility minimums of 460×320 that a hard 380-wide frame would clip,
/// so the window simply adopts whichever branch is showing).
struct RootView: View {
    /// Mirrors `DefaultOnboardingFlow.isCompleted()` — same exact key.
    @AppStorage(OnboardingConstants.completionKey) private var onboardingComplete = false

    var body: some View {
        Group {
            if onboardingComplete {
                MenuBarView()
            } else {
                OnboardingView {
                    // Fires right after the final step persisted the flag
                    // (and from the "Get started" fallback). Flipping this
                    // AppStorage-backed flag swaps in the dashboard.
                    onboardingComplete = true
                }
            }
        }
    }
}

#Preview("First run") {
    RootView()
}

#Preview("Returning user") {
    RootView()
        .onAppear { DefaultOnboardingFlow.setCompleted(true) }
}
