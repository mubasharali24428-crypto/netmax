import SwiftUI

/// Menu-bar app shell. `LSUIElement`-style: no Dock icon, lives in the menu bar.
///
/// Onboarding wiring (C2, B3's `OnboardingFlow`/`OnboardingView`) lives in
/// `RootView`: first-run users see onboarding inside this same menu-bar
/// window; afterwards the `MenuBarView` dashboard shows.
@main
struct NetMaxDesktopApp: App {
    var body: some Scene {
        MenuBarExtra {
            RootView()
        } label: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
