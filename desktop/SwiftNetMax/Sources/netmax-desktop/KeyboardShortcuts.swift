import SwiftUI

// MARK: - KeyboardShortcuts.swift
//
// Global keyboard shortcuts for the five-tab desktop shell.
//
// INTEGRATION NOTE (for the wave coordinator — RootView is NOT edited here):
//
//   `MainTabView` (RootView.swift) owns `@State private var selection = 0`
//   and drives `TabView(selection: $selection)` with tags 0–4. This file
//   only ships the reusable modifiers; wiring is a two-line change in
//   RootView once the coordinator exposes the binding, e.g.:
//
//       TabView(selection: $selection) { …existing tabs… }
//           .netMaxTabShortcuts(selection: $selection)   // ⌘1 … ⌘5 select tabs
//
//       // and, at any point inside the main-window hierarchy:
//       MainTabView()
//           .netMaxRerunLastShortcut()                   // ⌘R posts a rerun request
//
//   Consumers that implement "rerun last" (e.g. ModeLabView re-running the
//   previous benchmark) subscribe via:
//
//       NotificationCenter.default.publisher(for: .netmaxRerunLast)
//
//   Tag ↔ tab mapping lives in `NetMaxTab`, kept in lockstep with the
//   `.tag(0)…tag(4)` order declared in RootView.swift.
//
// Implementation detail: SwiftUI has no first-class "global shortcut" API
// inside a plain view hierarchy (`.commands` belongs to the Scene, which we
// don't own), so the standard hidden-Button technique is used: zero-sized,
// non-hit-testable, accessibility-hidden buttons whose `.keyboardShortcut`
// still registers with the key window. They are inert to mouse input.

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user presses ⌘R ("rerun last").
    ///
    /// Carries no `userInfo`; observers decide what "last" means for their
    /// surface (Mode Lab benchmark, History refresh, report export, …).
    static let netmaxRerunLast = Notification.Name("netmax.desktop.rerunLast")
}

// MARK: - Tab model

/// The five product tabs, mirroring `MainTabView`'s `.tag(0)…tag(4)` order.
enum NetMaxTab: Int, CaseIterable, Identifiable {
    case dashboard = 0
    case modeLab = 1
    case history = 2
    case reports = 3
    case settings = 4

    var id: Int { rawValue }

    /// Human-readable name; matches the `tabItem` labels in RootView.swift.
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .modeLab: return "Mode Lab"
        case .history: return "History"
        case .reports: return "Reports"
        case .settings: return "Settings"
        }
    }

    /// Digit key for the tab: ⌘1 for Dashboard … ⌘5 for Settings.
    var shortcutKey: KeyEquivalent {
        KeyEquivalent(Character(String(rawValue + 1)))
    }
}

// MARK: - ViewModifiers

/// Registers ⌘1 … ⌘5 to jump straight to the matching tab by writing the
/// tag value into the bound selection (the `TabView` selection binding).
struct NetMaxTabShortcutsModifier: ViewModifier {
    @Binding var selection: Int

    func body(content: Content) -> some View {
        content.background(
            ForEach(NetMaxTab.allCases) { tab in
                Button {
                    selection = tab.rawValue
                } label: {
                    Text("Show \(tab.title)")
                }
                .keyboardShortcut(tab.shortcutKey, modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        )
    }
}

/// Registers ⌘R and posts `.netmaxRerunLast` on the default center.
/// Nothing else about the app changes — observers opt in to the action.
struct NetMaxRerunLastShortcutModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            Button {
                NotificationCenter.default.post(name: .netmaxRerunLast, object: nil)
            } label: {
                Text("Rerun Last")
            }
            .keyboardShortcut("r", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        )
    }
}

// MARK: - View extensions (what the coordinator wires into RootView)

extension View {
    /// Adds ⌘1…⌘5 tab switching bound to a `TabView` selection (`Int` tags).
    func netMaxTabShortcuts(selection: Binding<Int>) -> some View {
        modifier(NetMaxTabShortcutsModifier(selection: selection))
    }

    /// Adds a ⌘R shortcut that posts `Notification.Name.netmaxRerunLast`.
    func netMaxRerunLastShortcut() -> some View {
        modifier(NetMaxRerunLastShortcutModifier())
    }
}
