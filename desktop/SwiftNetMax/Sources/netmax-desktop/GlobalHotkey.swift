import AppKit

/// W12 T5-a (suggestion S-001) — global hotkey ⌥⌘R: run Quick Test from any
/// app.
///
/// Uses NSEvent global + local monitors. The global monitor sees keystrokes
/// in OTHER apps; the local monitor covers our own windows (global monitors
/// do not fire for events aimed at this process). Both route to the same
/// handler, which posts `.netmaxRerunLast` — the notification MenuBarView's
/// Quick Test already observes.
///
/// Honest limitations:
/// - Accessibility-free global monitoring cannot intercept keys inside secure
///   fields (password managers); acceptable for a convenience hotkey.
/// - Requires the app to be running (it is — LSUIElement menu-bar app).
enum GlobalHotkey {
    private static var globalMonitor: Any?
    private static var localMonitor: Any?

    /// Idempotent install. Call once at app init.
    static func install() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            guard matches(event) else { return }
            post()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if matches(event) {
                post()
                return nil // consumed
            }
            return event
        }
    }

    static func uninstall() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    /// ⌥⌘R — mirrors the in-app ⌘R without colliding with it.
    private static func matches(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains([.command, .option])
            && event.keyCode == 15 // R
            && event.type == .keyDown
    }

    private static func post() {
        NotificationCenter.default.post(name: .netmaxRerunLast, object: nil)
    }
}
