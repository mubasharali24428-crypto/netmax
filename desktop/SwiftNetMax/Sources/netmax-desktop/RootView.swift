import SwiftUI

/// Single-window root for both the main window and the menu-bar popover.
///
/// Launch behavior: first run → honest-limits onboarding; afterwards the
/// six-tab product UI (L3 integration): Dashboard · Mode Lab · History ·
/// Schedule · Reports · Settings.
struct RootView: View {
    /// Mirrors `DefaultOnboardingFlow.isCompleted()` — same exact key.
    @AppStorage(OnboardingConstants.completionKey) private var onboardingComplete = false

    var body: some View {
        Group {
            if onboardingComplete {
                MainTabView()
            } else {
                OnboardingView {
                    // Fires right after the final step persisted the flag;
                    // flipping this AppStorage-backed flag swaps in the app.
                    onboardingComplete = true
                }
            }
        }
    }
}

/// Post-onboarding navigation. Sidebar on the main window feels native;
/// the same view works in the menu-bar popover where it collapses gracefully.
struct MainTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            MenuBarView()
                .tabItem { Label("Dashboard ⌘1", systemImage: "gauge") }
                .tag(0)
            // ALPHA-A4-06: attach the A2-09 Mode Lab a11y addendum here, at the
            // tab host, per ModeLabA11y.swift's header note (never inside
            // ModeLabView.swift itself).
            ModeLabView()
                .modeLabAccessibilityAddendum()
                .tabItem { Label("Mode Lab ⌘2", systemImage: "slider.horizontal.3") }
                .tag(1)
            HistoryView()
                .tabItem { Label("History ⌘3", systemImage: "clock.arrow.circlepath") }
                .tag(2)
            ScheduleEditorView()
                .tabItem { Label("Schedule ⌘6", systemImage: "clock.badge.checkmark") }
                .tag(5)
            ReportsView()
                .tabItem { Label("Reports ⌘4", systemImage: "square.and.arrow.up") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings ⌘5", systemImage: "gearshape") }
                .tag(4)
        }
        .accessibilityLabel("NetMax sections")
        .netMaxTabShortcuts(selection: $selection)
        .netMaxRerunLastShortcut()
    }
}

#Preview("First run") {
    RootView()
}

#Preview("Returning user") {
    RootView()
        .onAppear { DefaultOnboardingFlow.setCompleted(true) }
}
