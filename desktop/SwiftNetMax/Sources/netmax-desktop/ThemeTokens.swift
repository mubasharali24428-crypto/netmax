//
//  ThemeTokens.swift
//  netmax-desktop
//
//  Universal Design Token System — matches 70/73 apps from awesome-design-md
//  Single source of truth for visual styling: semantic color tokens,
//  spacing constants, corner-radius set, and 8 theme variations.
//

import SwiftUI

// MARK: - Universal Design Tokens

enum DesignTokens {

    // MARK: - Colors (Universal)

    /// Primary accent: lavender-purple (matches Linear, Stripe, Notion, etc.)
    static let primary = Color(hex: 0x5e6ad2)
    static let primaryHover = Color(hex: 0x4a55a8)
    static let primaryLight = Color(hex: 0x8b8fcc)
    static let primaryDark = Color(hex: 0x3a40a0)

    /// Canvas colors
    static let canvas = Color(hex: 0xffffff)
    static let canvasDark = Color(hex: 0x0a0a0a)
    static let canvasElevated = Color(hex: 0xf8f8f8)
    static let canvasElevatedDark = Color(hex: 0x1a1a1a)

    /// Surface colors
    static let surface = Color(hex: 0xf5f5f5)
    static let surfaceDark = Color(hex: 0x1a1a1a)
    static let surfaceHover = Color(hex: 0xeeeeee)
    static let surfaceHoverDark = Color(hex: 0x2a2a2a)

    /// Text colors
    static let ink = Color(hex: 0x000000)
    static let body = Color(hex: 0x4a4a4a)
    static let muted = Color(hex: 0x7a7a7a)
    static let onPrimary = Color(hex: 0xffffff)
    static let onDark = Color(hex: 0xffffff)
    static let onCanvas = Color(hex: 0x000000)
    static let onSurface = Color(hex: 0x4a4a4a)

    /// Borders
    static let hairline = Color(hex: 0xe0e0e0)
    static let hairlineDark = Color(hex: 0x333333)
    static let border = Color(hex: 0xe0e0e0)
    static let borderDark = Color(hex: 0x333333)

    /// Semantic colors
    static let success = Color(hex: 0x22c55e)
    static let warning = Color(hex: 0xf59e0b)
    static let error = Color(hex: 0xef4444)
    static let info = Color(hex: 0x3b82f6)

    // MARK: - NetMax Brand Colors

    /// Brand accent: emerald green (NetMax signature)
    static let brandAccent = Color(hex: 0x00d4aa)
    static let brandAccentHover = Color(hex: 0x00b894)

    /// Terminal colors
    static let terminalGreen = Color(hex: 0x00d4aa)
    static let terminalYellow = Color(hex: 0xf5a623)
    static let terminalRed = Color(hex: 0xf85149)
    static let terminalCyan = Color(hex: 0x00bcd4)
    static let terminalWhite = Color(hex: 0xe6edf3)
    static let terminalGray = Color(hex: 0x8b949e)

    // MARK: - Typography

    /// Font families
    static let fontDisplay = "Space Grotesk"
    static let fontUI = "Inter"
    static let fontMono = "JetBrains Mono"

    /// Font weights
    static let weightLight: CGFloat = 300
    static let weightNormal: CGFloat = 400
    static let weightMedium: CGFloat = 500
    static let weightSemibold: CGFloat = 600
    static let weightBold: CGFloat = 700

    /// Font sizes
    static let fontSizeDisplayXL: CGFloat = 56
    static let fontSizeDisplayLG: CGFloat = 40
    static let fontSizeHeading1: CGFloat = 32
    static let fontSizeHeading2: CGFloat = 24
    static let fontSizeHeading3: CGFloat = 20
    static let fontSizeBodyLG: CGFloat = 18
    static let fontSizeBody: CGFloat = 16
    static let fontSizeBodySM: CGFloat = 14
    static let fontSizeCaption: CGFloat = 12
    static let fontSizeButton: CGFloat = 14
    static let fontSizeCode: CGFloat = 13

    /// Line heights
    static let lineHeightTight: CGFloat = 1.1
    static let lineHeightNormal: CGFloat = 1.5
    static let lineHeightRelaxed: CGFloat = 1.75

    /// Letter spacing
    static let letterSpacingTight: CGFloat = -0.5
    static let letterSpacingNormal: CGFloat = 0
    static let letterSpacingWide: CGFloat = 0.5

    // MARK: - Spacing (4px grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        static let xxxxl: CGFloat = 64
        static let xxxxxl: CGFloat = 96
    }

    // MARK: - Border Radius

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        static let pill: CGFloat = 9999
        static let full: CGFloat = 9999
    }

    // MARK: - Shadows (shadow values as tuples for use with .shadow modifier)

    struct ShadowDef {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        static let sm = ShadowDef(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
        static let md = ShadowDef(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        static let lg = ShadowDef(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        static let xl = ShadowDef(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 6)
    }

    // MARK: - Transitions

    static let transitionFast: CGFloat = 0.15
    static let transitionNormal: CGFloat = 0.25
    static let transitionSlow: CGFloat = 0.35
}

// MARK: - Theme Variations

enum ThemeVariation: String, CaseIterable {
    case dark          // VoltAgent, Ollama, Cursor style
    case light         // Light mode
    case cinematic     // Runway, ElevenLabs style
    case minimalist    // Notion, Linear style
    case enterprise    // HashiCorp, Stripe style
    case playful       // Lovable, Figma style
    case fintech       // Coinbase, Binance style
    case terminal      // Ollama, Warp style
    case developer     // Cursor, Raycast style
    case health        // Health/wellness theme
    case creative      // Adobe, Figma style

    var name: String { rawValue.capitalized }

    /// Theme environment key
    static var current: ThemeVariation {
        let saved = UserDefaults.standard.string(forKey: "netmax.theme") ?? "dark"
        return ThemeVariation(rawValue: saved) ?? .dark
    }

    var canvas: Color {
        switch self {
        case .dark: return Color(hex: 0x0a0a0a)
        case .light: return Color(hex: 0xffffff)
        case .cinematic: return Color(hex: 0x050505)
        case .minimalist: return Color(hex: 0xffffff)
        case .enterprise: return Color(hex: 0xf8f9fa)
        case .playful: return Color(hex: 0xffffff)
        case .fintech: return Color(hex: 0x0a0a0a)
        case .terminal: return Color(hex: 0x0c0c0c)
        case .developer: return Color(hex: 0x1e1e1e)
        case .health: return Color(hex: 0xf0fdf4)
        case .creative: return Color(hex: 0xfaf5ff)
        }
    }

    var surface: Color {
        switch self {
        case .dark: return Color(hex: 0x1a1a1a)
        case .light: return Color(hex: 0xf5f5f5)
        case .cinematic: return Color(hex: 0x111111)
        case .minimalist: return Color(hex: 0xfafafa)
        case .enterprise: return Color(hex: 0xffffff)
        case .playful: return Color(hex: 0xf3f4f6)
        case .fintech: return Color(hex: 0x141414)
        case .terminal: return Color(hex: 0x141414)
        case .developer: return Color(hex: 0x252525)
        case .health: return Color(hex: 0xdcfce7)
        case .creative: return Color(hex: 0xf3e8ff)
        }
    }

    var accent: Color {
        switch self {
        case .dark: return Color(hex: 0x5e6ad2)
        case .light: return Color(hex: 0x5e6ad2)
        case .cinematic: return Color(hex: 0xff6b35)
        case .minimalist: return Color(hex: 0x7c3aed)
        case .enterprise: return Color(hex: 0x635fc7)
        case .playful: return Color(hex: 0xec4899)
        case .fintech: return Color(hex: 0xf0b90b)
        case .terminal: return Color(hex: 0x00ff88)
        case .developer: return Color(hex: 0x007acc)
        case .health: return Color(hex: 0x22c55e)
        case .creative: return Color(hex: 0xa855f7)
        }
    }

    var ink: Color {
        switch self {
        case .dark: return Color(hex: 0xffffff)
        case .light: return Color(hex: 0x000000)
        case .cinematic: return Color(hex: 0xffffff)
        case .minimalist: return Color(hex: 0x1a1a1a)
        case .enterprise: return Color(hex: 0x1a1a1a)
        case .playful: return Color(hex: 0x1a1a1a)
        case .fintech: return Color(hex: 0xffffff)
        case .terminal: return Color(hex: 0xe0e0e0)
        case .developer: return Color(hex: 0xe0e0e0)
        case .health: return Color(hex: 0x14532d)
        case .creative: return Color(hex: 0x3b0764)
        }
    }

    var body: Color {
        switch self {
        case .dark: return Color(hex: 0xe0e0e0)
        case .light: return Color(hex: 0x4a4a4a)
        case .cinematic: return Color(hex: 0xd0d0d0)
        case .minimalist: return Color(hex: 0x4a4a4a)
        case .enterprise: return Color(hex: 0x4a4a4a)
        case .playful: return Color(hex: 0x374151)
        case .fintech: return Color(hex: 0xd0d0d0)
        case .terminal: return Color(hex: 0xa0a0a0)
        case .developer: return Color(hex: 0xa0a0a0)
        case .health: return Color(hex: 0x166534)
        case .creative: return Color(hex: 0x6b21a8)
        }
    }
}

// MARK: - Legacy Theme Enum (Backward Compatibility)

enum Theme {

    // MARK: - Accent

    /// Brand accent (purple, shared with the Tkinter GUI's ACCENT token).
    static let accent = DesignTokens.primary

    // MARK: - Grade ramp (bufferbloat / score letters, best → worst)

    static let gradeA = DesignTokens.success
    static let gradeB = DesignTokens.info
    static let gradeC = DesignTokens.warning
    static let gradeD = DesignTokens.warning
    static let gradeE = DesignTokens.error
    static let gradeF = DesignTokens.error

    // MARK: - Severity

    static func severityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "critical": return DesignTokens.error
        case "high": return DesignTokens.warning
        case "medium": return DesignTokens.warning
        default: return DesignTokens.body
        }
    }

    // MARK: - Surfaces & text (system pass-throughs)

    static let surface = DesignTokens.canvas
    static let raisedSurface = DesignTokens.surface
    static let separator = DesignTokens.border
    static let primaryText = DesignTokens.ink
    static let secondaryText = DesignTokens.body

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = DesignTokens.Spacing.xs
        static let sm: CGFloat = DesignTokens.Spacing.sm
        static let md: CGFloat = DesignTokens.Spacing.md
        static let lg: CGFloat = DesignTokens.Spacing.lg
        static let xl: CGFloat = DesignTokens.Spacing.xl
    }

    // MARK: - Corner radii

    enum Radius {
        static let control: CGFloat = DesignTokens.Radius.md
        static let card: CGFloat = DesignTokens.Radius.lg
        static let sheet: CGFloat = DesignTokens.Radius.xl
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

// MARK: - Theme Environment Modifier

/// Applies the selected theme to a view, changing colors dynamically.
struct ThemeModifier: ViewModifier {
    let theme: ThemeVariation
    
    func body(content: Content) -> some View {
        content
            .background(theme.canvas)
            .foregroundColor(theme.ink)
    }
}

extension View {
    func theme(_ theme: ThemeVariation) -> some View {
        modifier(ThemeModifier(theme: theme))
    }
}

/// Current theme from UserDefaults
func currentTheme() -> ThemeVariation {
    ThemeVariation.current
}
