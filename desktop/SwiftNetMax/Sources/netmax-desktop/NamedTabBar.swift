import SwiftUI

/// W14 — Apple-native tab transitions + always-visible tab labels.
///
/// Two user-reported issues fixed:
/// 1. Tab switches were instant/hard cuts — now every tab cross-fades with a
///    subtle rise (opacity 0→1, offset y 8→0) using NetMaxMotion.standard.
///    Respects Reduce Motion (cross-fade only).
/// 2. In the menu-bar popover the system tab strip collapsed to icons-only,
///    hiding what each tab is. Replaced with an explicit custom tab bar:
///    icon + name always visible side-by-side, selected state accented.
///
/// The custom bar replaces the system one ONLY in the popover context
/// (`horizontalSizeClass == .compact`); the main window keeps the native
/// sidebar-style TabView which already shows names.
struct NamedTabBar: View {
    let selection: Binding<Int>

    private struct TabDef {
        let tag: Int
        let name: String
        let icon: String
        let help: String
    }

    private let tabs: [TabDef] = [
        .init(tag: 0, name: "Dashboard", icon: "gauge",
              help: "Dashboard — live metrics and Quick Test (⌘1)"),
        .init(tag: 1, name: "Mode Lab", icon: "slider.horizontal.3",
              help: "Mode Lab — all 10 measurement modes (⌘2)"),
        .init(tag: 2, name: "History", icon: "clock.arrow.circlepath",
              help: "History — past runs and trends (⌘3)"),
        .init(tag: 3, name: "Reports", icon: "square.and.arrow.up",
              help: "Reports — export CSV, JSON and PDF report cards (⌘4)"),
        .init(tag: 4, name: "Settings", icon: "gearshape",
              help: "Settings — plan, interpreter, notifications (⌘5)"),
        .init(tag: 5, name: "Schedule", icon: "clock.badge.checkmark",
              help: "Schedule — automatic testing on a timer (⌘6)"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.tag) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NetMax sections")
    }

    private func tabButton(_ tab: TabDef) -> some View {
        let isSelected = selection.wrappedValue == tab.tag
        return Button {
            withAnimation(NetMaxMotion.standard) {
                selection.wrappedValue = tab.tag
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                Text(tab.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.65))
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tab.help)
        .accessibilityLabel(Text(tab.name))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("Named tab bar") {
    NamedTabBar(selection: .constant(0))
}
