//
//  OnboardingFlow.swift
//  netmax-desktop
//
//  P0-B3 — Honest-limits onboarding state machine.
//
//  Contract C2 (verbatim, ATLAS-fixed):
//      protocol OnboardingFlow { var isComplete: Bool { get } mutating func advance() }
//
//  Four steps = the four honest-limits points from README.md ("Honest limits
//  — read this first"):
//    1) NetMax cannot exceed your ISP cap — nothing can;
//    2) turbo/boost gains appear only when the WiFi pipe is contended;
//    3) router-side QoS caps override everything here;
//    4) zero-throughput dropouts are reported honestly (airtime starvation),
//       not smoothed into a flattering percentage.
//
//  Persistence: UserDefaults Bool under the key EXACTLY
//  "netmax.onboarding.complete" — B1's shell reads the same key to decide
//  whether to show onboarding at launch. Self-contained: imports Foundation
//  only; no references to any other lane's types.
//

import Foundation

/// Contract C2 — ATLAS-fixed; do not alter without coordinator sign-off.
protocol OnboardingFlow {
    var isComplete: Bool { get }
    mutating func advance()
}

/// One honest-limits point shown during onboarding.
struct OnboardingStep: Equatable {
    let title: String
    let bodyText: String
}

/// UserDefaults key shared with B1's shell — EXACT spelling, do not rename.
enum OnboardingConstants {
    static let completionKey = "netmax.onboarding.complete"
}

/// C2 reference state machine over the four honest-limits steps.
struct DefaultOnboardingFlow: OnboardingFlow {
    /// Total number of onboarding steps (fixed at four for P0).
    static let totalSteps = 4

    /// Index of the step currently presented (0-based).
    private(set) var stepIndex: Int

    /// Starts (or resumes) the flow. `stepIndex` is clamped into range so a
    /// corrupted persisted value can never crash the shell.
    init(stepIndex: Int = 0) {
        self.stepIndex = min(max(stepIndex, 0), DefaultOnboardingFlow.totalSteps - 1)
    }

    /// The step currently on screen; `nil` once the flow has completed.
    var currentStep: OnboardingStep? {
        guard !isComplete else { return nil }
        return DefaultOnboardingFlow.steps[stepIndex]
    }

    /// 1-based position for the "step x/4" ProgressView label.
    var currentStepNumber: Int { stepIndex + 1 }

    /// Contract C2: true only after the fourth step has been advanced past.
    var isComplete: Bool {
        stepIndex >= DefaultOnboardingFlow.totalSteps
    }

    /// Contract C2: move forward one step. Advancing past the final step
    /// completes the flow (idempotent — further calls are no-ops).
    mutating func advance() {
        guard stepIndex < DefaultOnboardingFlow.totalSteps else { return }
        stepIndex += 1
    }

    /// Move back one step. No-op on the first step (the view also disables
    /// its Back button there; this guards programmatic callers).
    mutating func goBack() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
    }

    // MARK: - Honest-limits copy (source: README.md)

    static let steps: [OnboardingStep] = [
        OnboardingStep(
            title: "Your ISP cap is the ceiling",
            bodyText: "NetMax cannot exceed your ISP cap — no software can. The cap is "
                + "enforced on the provider's side; anyone promising to \"10x your "
                + "speed\" is selling scamware."
        ),
        OnboardingStep(
            title: "Gains need a contended pipe",
            bodyText: "Turbo and boost gains appear only when your WiFi pipe is contended "
                + "(other devices pulling traffic). On an idle line, baseline already "
                + "is your plan speed."
        ),
        OnboardingStep(
            title: "Router QoS overrides everything",
            bodyText: "Router-side QoS caps override everything NetMax does. Only the "
                + "router admin or a plan upgrade can change those limits."
        ),
        OnboardingStep(
            title: "Dropouts reported honestly",
            bodyText: "Zero-throughput windows on shared WiFi are real (airtime "
                + "starvation). NetMax reports them as dropouts rather than inventing "
                + "a flattering percentage."
        ),
    ]

    // MARK: - Persistence (shared with B1)

    /// Reads the shared completion flag. Defaults to false when absent or
    /// stored under an unexpected type.
    static func isCompleted() -> Bool {
        UserDefaults.standard.bool(forKey: OnboardingConstants.completionKey)
    }

    /// Writes the shared completion flag under the exact B1-shared key.
    static func setCompleted(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: OnboardingConstants.completionKey)
    }
}
