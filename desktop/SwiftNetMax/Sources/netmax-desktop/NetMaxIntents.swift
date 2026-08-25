import AppIntents
import SwiftUI

/// W11-A-194 — Shortcuts.app + Siri actions for NetMax.
///
/// AppIntents (macOS 13+): exposes "Run Quick Test" and "Get Latest Result"
/// so users can build automations, ask Siri, or chain NetMax into their own
/// shortcuts. The UI surfaces this in Settings → Keyboard Shortcuts row's
/// sibling: "Shortcuts & Siri" (added by ATLAS in SettingsView).
///
/// Honest scope note: AppIntents run IN this process, so a Quick Test intent
/// reuses the same EngineClient path as the popover button.

struct RunQuickTestIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Quick Test"
    static var description = IntentDescription(
        "Runs the NetMax quick speed test and returns the measured result."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let client = EngineClient()
        let output = try await client.run("boost", args: ["--seconds", "5"])
        return .result(value: output)
    }
}

struct GetLatestResultIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Result"
    static var description = IntentDescription(
        "Returns the most recent saved measurement summary."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let records = HistoryStore.shared.loadAll()
        guard let last = records.last else {
            return .result(value: "No measurements yet.")
        }
        let summary = ReportCardShareComposer.summaryText(
            for: ReportCardModel.makeCard(from: [last])
        )
        return .result(value: summary)
    }
}

struct NetMaxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunQuickTestIntent(),
            phrases: ["Run a \(.applicationName) quick test"],
            shortTitle: "Run Quick Test",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: GetLatestResultIntent(),
            phrases: ["Show my last \(.applicationName) result"],
            shortTitle: "Latest Result",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
