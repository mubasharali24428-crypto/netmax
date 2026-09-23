import SwiftUI

/// W10-4 (P2b) — feature discovery: one section in Settings telling new users
/// what NetMax can do, each row deep-linking to the feature. Wayfinding per
/// apple-design §16: every screen answers "what's there?".
struct FeatureDiscoverySection: View {
    /// Callback so SettingsView can switch the root tab (tag values match
    /// RootView.MainTab rawValues).
    let openTab: (Int) -> Void

    var body: some View {
        Section("What NetMax can do") {
            featureRow(
                icon: "chart.dots.scatter",
                title: "Quality Timeline",
                pitch: "Your runs as a timeline with WiFi events",
                tabTag: 2 // History
            )
            featureRow(
                icon: "doc.richtext",
                title: "ISP Report Cards",
                pitch: "Grade your ISP and export a PDF",
                tabTag: 3 // Reports
            )
            featureRow(
                icon: "clock.badge.checkmark",
                title: "Automatic Testing",
                pitch: "Schedule checks even when you're away",
                tabTag: 5 // Schedule
            )
            featureRow(
                icon: "command",
                title: "Shortcuts & Siri",
                pitch: "⌘1–⌘6 tabs, ⌘R rerun — plus Shortcuts app actions",
                tabTag: 4 // Settings (this page documents them)
            )
        }
    }

    private func featureRow(icon: String, title: String, pitch: String, tabTag: Int) -> some View {
        Button {
            openTab(tabTag)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(pitch).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(NetMaxPressStyle())
    }
}
