//
//  EmptyStateViews.swift
//  netmax-desktop
//
//  ALPHA-A2-05 — Reusable empty-state blocks: friendly illustrated-text
//  placeholders for the moments a tab has nothing to show yet.
//
//  Four shipped configurations (one per known surface):
//      .noHistory(...)              — History log is empty
//      .noResultsToExport(...)      — Reports has no saved result to export
//      .scheduleNotConfigured(...)  — scheduling pane has no times set
//      .notificationsDisabled(...)  — user has notifications turned off
//
//  Every configuration carries exactly ONE action button (title + closure),
//  supplied by the hosting tab, so the same block works in the main window
//  and the menu-bar popover without knowing about navigation.
//
//  Copy follows the honest-limits voice from README.md / onboarding: say
//  what isn't happening, never promise gains, point at the real next step.
//  Visuals use only system semantic colors (.primary/.secondary/accent at
//  low opacity) for WCAG-AA contrast in light and dark mode.
//


import SwiftUI

/// An illustrated-text placeholder with a single action button.
///
/// Usage in a tab:
///
///     if records.isEmpty {
///         EmptyStateView.noHistory {
///             goToModeLab()
///         }
///     }
///
/// The base layout centers horizontally and pads itself, so it drops cleanly
/// into List sections and scrollable stacks. For a standalone pane (like
/// Reports' main area), append `.framedForPane()` to also center vertically.
struct EmptyStateView: View {

    // MARK: Configuration

    /// SF Symbol drawn inside the illustration disc.
    let symbolName: String

    /// Short headline naming the empty situation.
    let title: String

    /// One-to-three-sentence explanation in the honest-limits voice.
    let message: String

    /// Title of the block's single action button.
    var buttonTitle: String

    /// Called when the action button is clicked. Host decides what happens;
    /// the view stays navigation-agnostic for reuse across tabs.
    var action: () -> Void

    /// Stable accessibility identifier for UI tests. Presets supply their own.
    var identifier: String = "empty.state"

    // MARK: View

    var body: some View {
        VStack(spacing: 14) {
            illustration
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340)
            // VoiceOver reads headline + explanation as one element; the
            // button stays separately focusable below.
            .accessibilityElement(children: .combine)

            Button(action: action) {
                Text(buttonTitle)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(Text(buttonTitle))
            .accessibilityHint(Text("Activates the suggested next step for this empty state."))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(identifier)
    }

    /// Placeholder illustration: a dashed ring (the "slot waiting to be
    /// filled") around an accent-tinted disc holding the state's symbol.
    private var illustration: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    Color.accentColor.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .frame(width: 88, height: 88)

            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 62, height: 62)

            Image(systemName: symbolName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
        }
    }
}

// MARK: - Layout helpers

extension EmptyStateView {

    /// Vertical centering for standalone panes (Reports, scheduling).
    /// Inside List sections or scroll views, prefer the plain form.
    func framedForPane() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shipped configurations

extension EmptyStateView {

    /// History tab: the log holds no runs yet.
    ///
    /// - Parameters:
    ///   - buttonTitle: Override for the default call to action.
    ///   - action: Invoked by the button; typically switches to Mode Lab.
    /// - Returns: A configured empty-state block ("no history yet").
    static func noHistory(
        buttonTitle: String = "Run Your First Measurement",
        action: @escaping () -> Void
    ) -> EmptyStateView {
        EmptyStateView(
            symbolName: "clock.arrow.circlepath",
            title: "No history yet",
            message: "Measurements appear here after your first run in Mode Lab. "
                + "NetMax records only what you actually run — nothing is "
                + "preloaded or estimated.",
            buttonTitle: buttonTitle,
            action: action,
            identifier: "empty.history"
        )
    }

    /// Reports tab: there is no saved result to export.
    ///
    /// - Parameters:
    ///   - buttonTitle: Override for the default call to action.
    ///   - action: Invoked by the button; typically switches to Mode Lab.
    /// - Returns: A configured empty-state block ("no results to export").
    static func noResultsToExport(
        buttonTitle: String = "Run a Measurement",
        action: @escaping () -> Void
    ) -> EmptyStateView {
        EmptyStateView(
            symbolName: "doc.text.magnifyingglass",
            title: "Nothing to export yet",
            message: "Exports need at least one saved result. Run a measurement "
                + "and it will be ready here as CSV or JSON — NetMax doesn't "
                + "export placeholder numbers.",
            buttonTitle: buttonTitle,
            action: action,
            identifier: "empty.export"
        )
    }

    /// Scheduling pane: no measurement times are configured.
    ///
    /// - Parameters:
    ///   - buttonTitle: Override for the default call to action.
    ///   - action: Invoked by the button; typically opens the schedule editor.
    /// - Returns: A configured empty-state block ("schedule not configured").
    static func scheduleNotConfigured(
        buttonTitle: String = "Configure a Schedule",
        action: @escaping () -> Void
    ) -> EmptyStateView {
        EmptyStateView(
            symbolName: "calendar.badge.clock",
            title: "Schedule not configured",
            message: "Nothing runs in the background until you set times here. "
                + "You can still measure manually whenever you like from Mode Lab.",
            buttonTitle: buttonTitle,
            action: action,
            identifier: "empty.schedule"
        )
    }

    /// Notification-dependent surfaces: notifications are disabled.
    ///
    /// - Parameters:
    ///   - buttonTitle: Override for the default call to action.
    ///   - action: Invoked by the button; typically deep-links to
    ///     System Settings notification options.
    /// - Returns: A configured empty-state block ("notifications disabled").
    static func notificationsDisabled(
        buttonTitle: String = "Open System Settings",
        action: @escaping () -> Void
    ) -> EmptyStateView {
        EmptyStateView(
            symbolName: "bell.slash",
            title: "Notifications are off",
            message: "Everything still works without them — finished runs land "
                + "in History either way. Turn notifications on if you'd like "
                + "a heads-up when long runs finish.",
            buttonTitle: buttonTitle,
            action: action,
            identifier: "empty.notifications"
        )
    }
}

#if DEBUG
#Preview("All four states") {
    ScrollView {
        VStack(spacing: 0) {
            Divider()
            EmptyStateView.noHistory {}
            Divider()
            EmptyStateView.noResultsToExport {}
            Divider()
            EmptyStateView.scheduleNotConfigured {}
            Divider()
            EmptyStateView.notificationsDisabled {}
        }
    }
    .frame(width: 520, height: 720)
}

#Preview("Popover-width pane") {
    EmptyStateView.scheduleNotConfigured {}
        .framedForPane()
        .frame(width: 340, height: 300)
}
#endif
