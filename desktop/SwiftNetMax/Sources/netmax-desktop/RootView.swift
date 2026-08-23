import SwiftUI

/// Single-window root for both the main window and the menu-bar popover.
///
/// Launch behavior: first run → honest-limits onboarding; afterwards the
/// five-tab product UI (L3 integration): Dashboard · Mode Lab · History ·
/// Reports · Settings.
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
                .tabItem { Label("Dashboard", systemImage: "gauge") }
                .tag(0)
            ModeLabView()
                .tabItem { Label("Mode Lab", systemImage: "slider.horizontal.3") }
                .tag(1)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(2)
            ReportsView()
                .tabItem { Label("Reports", systemImage: "square.and.arrow.up") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
        .accessibilityLabel("NetMax sections")
    }
}

#Preview("First run") {
    RootView()
}

#Preview("Returning user") {
    RootView()
        .onAppear { DefaultOnboardingFlow.setCompleted(true) }
}
