import SwiftUI

/// Menu-bar app shell. `LSUIElement`-style: no Dock icon, lives in the menu bar.
///
/// Onboarding wiring (C2, B3's `OnboardingFlow`/`OnboardingView`) is intentionally
/// left to the merge step — this shell shows `MenuBarView` directly and the
/// coordinator inserts the onboarding gate at the PairA seam.
@main
struct NetMaxDesktopApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
