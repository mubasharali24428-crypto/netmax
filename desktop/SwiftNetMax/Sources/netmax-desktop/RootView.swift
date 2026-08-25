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

/// Post-onboarding navigation.
///
/// W14: the menu-bar popover uses a CUSTOM tab bar (NamedTabBar) with
/// icon + name always visible — the system tab strip collapsed to bare icons
/// at popover width, hiding what each tab is (user-reported). The main window
/// keeps the native sidebar-style TabView which shows names natively.
/// Both paths animate tab changes with a smooth cross-fade + rise.
struct MainTabView: View {
    /// W12 T4-c (audit 164): the selected tab persists across launches under
    /// `netmax.state.lastTab`. `TabView(selection:)` writes straight through
    /// this binding, so the @AppStorage property observer does the saving.
    @AppStorage("netmax.state.lastTab") private var selection = 0

    /// W10-4: binding wrapper so deep views (Settings feature cards) can
    /// switch tabs without owning state.
    private var tabSelection: Binding<Int> {
        Binding(get: { selection }, set: { selection = $0 })
    }

    /// W14: true when running inside the compact menu-bar popover context —
    /// drives the custom named tab bar instead of the system strip.
    @Environment(\.controlActiveState) private var controlActive
    @AppStorage("netmax.prefs.launchWindow") private var showWindow = true

    var body: some View {
        if isPopoverContext {
            popoverLayout
        } else {
            nativeTabView
        }
    }

    /// The popover hosts RootView with a small min-width; the main window is
    /// wider. Width alone distinguishes them reliably without new plumbing.
    @State private var width: CGFloat = 0

    private var isPopoverContext: Bool { width > 0 && width < 400 }

    private var popoverLayout: some View {
        VStack(spacing: 0) {
            NamedTabBar(selection: tabSelection)
            tabContent
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { width = $0 }
        })
    }

    private var nativeTabView: some View {
        TabView(selection: tabSelection) {
            MenuBarView()
                .tabItem { Label("Dashboard ⌘1", systemImage: "gauge") }
                .help("Dashboard — live metrics and Quick Test (⌘1)")
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
            SettingsView(onOpenTab: { selection = $0 })
                .tabItem { Label("Settings ⌘5", systemImage: "gearshape") }
                .tag(4)
        }
        .accessibilityLabel("NetMax sections")
        .netMaxTabShortcuts(selection: $selection)
        .netMaxRerunLastShortcut()
    }

    /// W14: the tab content with a smooth cross-fade + rise on switch.
    /// Each tab's view animates opacity/offset keyed to selection so moving
    /// between tabs feels like one continuous surface, not hard cuts.
    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            pane(0) { MenuBarView() }
            pane(1) { ModeLabView().modeLabAccessibilityAddendum() }
            pane(2) { HistoryView() }
            pane(3) { ReportsView() }
            pane(4) { SettingsView(onOpenTab: { selection = $0 }) }
            pane(5) { ScheduleEditorView() }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : NetMaxMotion.standard,
                   value: selection)
        .accessibilityLabel("NetMax sections")
        .netMaxTabShortcuts(selection: $selection)
        .netMaxRerunLastShortcut()
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private func pane<Content: View>(_ tag: Int,
                                     @ViewBuilder content: () -> Content) -> some View {
        let isActive = selection == tag
        Group {
            if isActive {
                content()
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: 8)))
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
