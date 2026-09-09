import SwiftUI

/// NetMax desktop shell.
///
/// Surfaces:
/// - **Main window** (auto-opens at launch unless disabled in Settings):
///   hosts `RootView` — first-run honest-limits onboarding, then the
///   five-tab product UI (Dashboard · Mode Lab · History · Reports · Settings).
/// - **Menu bar bolt icon** (⚡): popover hosting the same `RootView`.
///
/// No Dock icon (`LSUIElement`) — accessory-style app.
///
/// NOTE: the launch-window toggle is read via a ScenePhase-free wrapper
/// because conditional Scene builders choke older swiftc diagnostics; the
/// WindowGroup is always declared, and RootView itself decides whether to
/// render content or an empty placeholder based on the same preference.
@main
struct NetMaxDesktopApp: App {
    /// Wave-3 automation boot: status publisher + scheduler tick loop.
    /// Both are idempotent singletons — safe here, once per process.
    init() {
        StatusPublisherHook.install()
        // W18 (audit F2 follow-up): refuse-to-auto-run guard when the
        // bundled engine dir is group/world-writable pre-notarization.
        EngineIntegrityCheck.runAtStartup()
#if DEBUG
        // Offline harness lane for EngineIntegrityCheckTests (HistoryStoreTests
        // convention): runs once at dev-launch so a regression fails loudly.
        if EngineIntegrityCheckTests.runAll() > 0 {
            NSLog("EngineIntegrityCheckTests: FAILURES — see console")
        }
#endif
        ScheduleRunner.shared.start()
        // W13 dial fix: start the throughput sampler EAGERLY so the
        // speedometer is live from launch on any surface — a Mode Lab run
        // must show its traffic on the Dashboard dial even if the Dashboard
        // tab was never opened (Swift static lets are lazy).
        _ = ThroughputSampler.shared
        // W13B TEAM-UB / UB-5 (S-019): UNUserNotificationCenter delegate —
        // notification taps activate the app and open the relevant tab.
        NotificationsDelegate.install()
        // W12 T5-a hotkey DISABLED: NSEvent global key monitors starve the
        // main event loop (app window drew but ignored all clicks). Proper
        // fix = Carbon RegisterEventHotKey, queued for next batch.
        // GlobalHotkey.install()
    }

    var body: some Scene {
        WindowGroup("NetMax", id: "main") {
            LaunchWindowGate()
                .frame(
                    minWidth: 420, idealWidth: 460,
                    minHeight: 520, idealHeight: 600
                )
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            RootView()
                .frame(minWidth: 380, idealWidth: 420,
                       minHeight: 480, idealHeight: 560)
        } label: {
            // Live status: shows the published quick-status line
            // (`⚡ 29 Mbps · B · 12m ago`, written by StatusBarController.publish)
            // and falls back to the bolt glyph until/unless a label exists.
            StatusBarController.LabelView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Shows the real UI in the main window only when
/// `netmax.prefs.launchWindow` is true (default). Otherwise renders an
/// unobtrusive placeholder — the app keeps living in the menu bar.
private struct LaunchWindowGate: View {
    @AppStorage("netmax.prefs.launchWindow") private var showWindow = true

    var body: some View {
        if showWindow {
            RootView()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("NetMax runs from the ⚡ menu-bar icon.")
                    .font(.headline)
                Text("Re-enable “Open main window at startup” in Settings to bring this window back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}
