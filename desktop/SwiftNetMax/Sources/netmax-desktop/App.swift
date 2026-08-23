import SwiftUI

/// NetMax desktop shell.
///
/// Surfaces:
/// - **Main window** (auto-opens at launch): hosts `RootView`, which shows
///   first-run honest-limits onboarding, then the dashboard. This exists so
///   launching the app has an obvious, visible result — a menu-bar icon
///   alone reads as "nothing happened".
/// - **Menu bar bolt icon** (⚡): always-available popover hosting the same
///   `RootView`. Both instances share `@AppStorage` state, so completing
///   onboarding in one instantly updates the other.
///
/// No Dock icon (`LSUIElement` in Info.plist) — the app stays accessory-style.
@main
struct NetMaxDesktopApp: App {
    var body: some Scene {
        WindowGroup("NetMax", id: "main") {
            RootView()
                .frame(
                    minWidth: 380, idealWidth: 410,
                    minHeight: 430, idealHeight: 550
                )
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            RootView()
        } label: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
