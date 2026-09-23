// AUDIT M9: not mounted in production — wire or remove deliberately.

//
//  WifiDashboardSection.swift
//  netmax-desktop
//
//  ALPHA-A3-09 (wave-3, sub-wave W3a) — Dashboard "Wi‑Fi" section.
//
//  A drop-in DASHBOARD SECTION that wraps Lane A2-03's WifiPanelView and
//  sizes it for embedding in the Dashboard tab (MenuBarView). The panel
//  keeps owning all behavior — engine access stays exclusively inside
//  WifiPanelView via `EngineClient.run("wifi")` (contract C1/L2, no flags),
//  and persistence stays on `HistoryStore.shared.append/loadAll`
//  (contract P2). This wrapper adds zero new data flow; it is layout,
//  chrome, and an accessibility boundary only.
//
//  ═══════════════════════════════════════════════════════════════════
//  INTEGRATION NOTE — for the wiring lane (MenuBarView owners, later wave)
//  ═══════════════════════════════════════════════════════════════════
//    • Drop-in use: place `WifiDashboardSection()` anywhere in the
//      Dashboard column. No other setup, no callbacks, no bindings.
//    • WIDTH FLOOR: WifiPanelView carries an internal
//      `.frame(minWidth: 360, minHeight: 300)`. Host the section in a
//      container ≥ 360 pt wide (e.g. widen the Dashboard window past its
//      current 380 pt total, or lay the section out full-width). Below
//      that floor SwiftUI will overflow, not squeeze.
//    • DUPLICATE TITLE: the wrapped panel draws its own "Wi‑Fi"
//      headline header. This section's compact caption is additive and
//      can be suppressed with `WifiDashboardSection(showsCaption: false)`
//      if the surrounding layout already titles the area.
//    • CHROME: default card surface/border matches DashboardCardsView's
//      MetricCard tiles (Theme.Radius.card, Theme.raisedSurface,
//      Theme.separator). Turn off with `showsChrome: false` for a flat
//      section inside an already-carded host.
//    • OWNERSHIP: this file is NEW and self-contained. MenuBarView.swift,
//      RootView.swift, App.swift and WifiPanelView.swift are NOT edited
//      here; wire the section from the owner lanes in a later sub-wave.
//

import SwiftUI

/// Dashboard-embeddable Wi‑Fi section: compact "Wi‑Fi" caption above the
/// full WifiPanelView, wrapped in the dashboard's card chrome.
///
/// Stateless by design — every knob is an initializer flag with a sensible
/// default, so the wiring lane can adopt it with a single line and tune
/// later without touching this file's logic.
struct WifiDashboardSection: View {
    /// Show the compact section caption ("WI-FI" eyebrow) above the panel.
    /// Off when the host layout already provides a Wi‑Fi title.
    var showsCaption: Bool = true

    /// Show the dashboard card surface + hairline border. Off when the
    /// host supplies its own card chrome.
    var showsChrome: Bool = true

    var body: some View {
        Group {
            if showsChrome {
                sectionContent
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .fill(Theme.raisedSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.separator)
                    )
            } else {
                sectionContent
            }
        }
    }

    // MARK: - Section content

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if showsCaption {
                caption
            }
            WifiPanelView()
                // Flex with whatever width the dashboard hands us; the
                // panel's own minWidth: 360 floor still applies (see the
                // integration note above).
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }

    /// Compact eyebrow caption sized for dashboard embedding — deliberately
    /// smaller than the panel's internal headline so the two never compete.
    private var caption: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "wifi")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text("Wi\u{2011}Fi")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wi\u{2011}Fi")
    }
}

#Preview("Dashboard section · full chrome") {
    WifiDashboardSection()
        .frame(width: 440)
}

#Preview("Flat, captionless (host-titled)") {
    WifiDashboardSection(showsCaption: false, showsChrome: false)
        .frame(width: 400)
        .padding()
}
