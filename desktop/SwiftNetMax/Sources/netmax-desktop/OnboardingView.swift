//
//  OnboardingView.swift
//  netmax-desktop
//
//  P0-B3 — SwiftUI front end for the honest-limits onboarding flow.
//
//  Accessibility notes:
//  - Every control carries an accessibilityLabel (+ hints where useful);
//    VoiceOver reads step title/body as one combined element.
//  - Keyboard navigable: buttons are natively focusable under Full Keyboard
//    Access; Return activates Continue (default action), ← activates Back.
//  - WCAG AA contrast: only system semantic colors (.primary/.secondary) —
//    no custom low-contrast palette.
//

import SwiftUI

struct OnboardingView: View {
    /// The observable-equivalent state machine driving this view.
    @State private var flow = DefaultOnboardingFlow()

    /// Fired exactly once, right after the fourth step's Continue persists
    /// the completion flag. Host (B1's shell) dismisses the window here.
    var onComplete: () -> Void = {}

    var body: some View {
        Group {
            if let step = flow.currentStep {
                stepLayout(step)
            } else {
                completedLayout
            }
        }
        .padding(28)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 380)
        .accessibilityIdentifier("onboarding.root")
    }

    // MARK: - Step layout

    private func stepLayout(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            progressHeader

            VStack(alignment: .leading, spacing: 12) {
                Text(step.title)
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.primary)
                Text(step.bodyText)
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)
            controls
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: Double(flow.currentStepNumber),
                total: Double(DefaultOnboardingFlow.totalSteps)
            )
            .accessibilityLabel(Text("Onboarding progress"))
            .accessibilityValue(
                Text("Step \(flow.currentStepNumber) of \(DefaultOnboardingFlow.totalSteps)")
            )

            Text("Step \(flow.currentStepNumber) of \(DefaultOnboardingFlow.totalSteps)")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true) // duplicated by the value above
        }
        .accessibilityIdentifier("onboarding.progress")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                flow.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(flow.stepIndex == 0)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel(Text("Back"))
            .accessibilityHint(Text("Returns to the previous step."))
            .accessibilityIdentifier("onboarding.back")

            Spacer()

            Button {
                continueTapped()
            } label: {
                Text("Continue").frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text("Continue"))
            .accessibilityHint(isOnFinalStep
                ? Text("Finishes onboarding.")
                : Text("Advances to step \(flow.currentStepNumber + 1) of \(DefaultOnboardingFlow.totalSteps)."))
            .accessibilityIdentifier("onboarding.continue")
        }
    }

    private var isOnFinalStep: Bool {
        flow.stepIndex == DefaultOnboardingFlow.totalSteps - 1
    }

    /// Fallback shown if the host keeps the view mounted after completion,
    /// so the window never goes blank.
    private var completedLayout: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(.title2.weight(.semibold))
            Text("NetMax will measure what your connection truly delivers and report its limits honestly.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Get started") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text("Get started"))
            .accessibilityIdentifier("onboarding.get-started")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func continueTapped() {
        flow.advance()
        guard flow.isComplete else { return }
        // Persist the exact shared key ("netmax.onboarding.complete", Bool)
        // so B1's shell skips onboarding on next launch.
        DefaultOnboardingFlow.setCompleted(true)
        onComplete()
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            OnboardingView()
            OnboardingView(stepIndexOverride: 3)
        }
    }
}

/// Debug-only initializer surface used by previews; lives outside the shipped
/// memberwise shape so production call sites stay `{ }`-closure-only.
private extension OnboardingView {
    init(stepIndexOverride: Int) {
        self.init(onComplete: {})
        _flow = State(initialValue: DefaultOnboardingFlow(stepIndex: stepIndexOverride))
    }
}
#endif
