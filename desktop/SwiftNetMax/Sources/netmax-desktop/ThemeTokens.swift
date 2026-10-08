import SwiftUI
import AppKit

// MARK: - Universal Design Tokens

enum DesignTokens {
    @Environment(\.colorScheme) static var colorScheme

    static func dynamicColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let r = CGFloat((hex >> 16) & 0xFF) / 255.0
            let g = CGFloat((hex >> 8) & 0xFF) / 255.0
            let b = CGFloat(hex & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }))
    }

    // Semantic roles
    static let canvas = dynamicColor(light: 0xF7F8FA, dark: 0x101318)
    static let surface = dynamicColor(light: 0xFFFFFF, dark: 0x1A2028)
    static let primaryText = dynamicColor(light: 0x1A1D24, dark: 0xF3F4F6)
    static let secondaryText = dynamicColor(light: 0x4B5563, dark: 0xC1C7D0)
    static let accent = dynamicColor(light: 0x4F46E5, dark: 0xA5B4FC)
    static let focus = dynamicColor(light: 0x4338CA, dark: 0xC4B5FD)

    static let success = dynamicColor(light: 0x059669, dark: 0x4ADE80)
    static let warning = dynamicColor(light: 0xB45309, dark: 0xFBBF24)
    static let error = dynamicColor(light: 0xDC2626, dark: 0xF87171)
    static let info = dynamicColor(light: 0x2563EB, dark: 0x60A5FA)

    // Legacy aliases preserved for named callers (DashboardCardsView uses DesignTokens.ink)
    static let ink = primaryText
    static let primary = accent
    static let border = dynamicColor(light: 0xD1D5DB, dark: 0x374151) // Needed for backwards compat

    // Type scale
    // system UI type for macOS
    // display 28/34, title 20/26, body 14/20, caption 12/16, and data-mono 12/18.
    // SwiftUI Font doesn't strictly set line height directly, we use .system with sizes
    enum Typography {
        static let display = Font.system(size: 28, weight: .bold)
        static let title = Font.system(size: 20, weight: .semibold)
        static let body = Font.system(size: 14, weight: .regular)
        static let caption = Font.system(size: 12, weight: .regular)
        static let dataMono = Font.system(size: 12, weight: .regular, design: .monospaced)
    }

    // Spacing
    enum Spacing {
        static let p4: CGFloat = 4
        static let p8: CGFloat = 8
        static let p12: CGFloat = 12
        static let p16: CGFloat = 16
        static let p24: CGFloat = 24
        static let p32: CGFloat = 32
        static let p48: CGFloat = 48

        // Aliases for compatibility
        static let xs = p4
        static let sm = p8
        static let md = p12
        static let lg = p16
        static let xl = p24
    }

    enum Radius {
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16

        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 16
    }
}

// MARK: - Legacy Theme Enum (Backward Compatibility)
enum Theme {
    static let accent = DesignTokens.accent
    static let gradeA = DesignTokens.success
    static let gradeB = DesignTokens.info
    static let gradeC = DesignTokens.warning
    static let gradeD = DesignTokens.warning
    static let gradeE = DesignTokens.error
    static let gradeF = DesignTokens.error

    static func severityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "critical": return DesignTokens.error
        case "high": return DesignTokens.warning
        case "medium": return DesignTokens.warning
        default: return DesignTokens.secondaryText
        }
    }

    static let surface = DesignTokens.canvas
    static let raisedSurface = DesignTokens.surface
    static let separator = DesignTokens.border
    static let primaryText = DesignTokens.primaryText
    static let secondaryText = DesignTokens.secondaryText

    enum Spacing {
        static let xs = DesignTokens.Spacing.xs
        static let sm = DesignTokens.Spacing.sm
        static let md = DesignTokens.Spacing.md
        static let lg = DesignTokens.Spacing.lg
        static let xl = DesignTokens.Spacing.xl
    }

    enum Radius {
        static let control = DesignTokens.Radius.control
        static let card = DesignTokens.Radius.card
        static let sheet = DesignTokens.Radius.sheet
    }
}

// MARK: - Theme Variations
// Only support system light and dark
enum ThemeVariation: String, CaseIterable {
    case dark
    case light

    var name: String { rawValue.capitalized }

    static var current: ThemeVariation {
        let saved = UserDefaults.standard.string(forKey: "netmax.theme") ?? "dark"
        return ThemeVariation(rawValue: saved) ?? .dark
    }
}

struct ThemeModifier: ViewModifier {
    let theme: ThemeVariation
    @Environment(\.colorScheme) var systemColorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, theme == .dark ? .dark : .light)
    }
}

extension View {
    func theme(_ theme: ThemeVariation) -> some View {
        modifier(ThemeModifier(theme: theme))
    }
}

func currentTheme() -> ThemeVariation {
    ThemeVariation.current
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
