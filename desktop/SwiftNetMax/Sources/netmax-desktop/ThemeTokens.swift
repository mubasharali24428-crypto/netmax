//
//  ThemeTokens.swift
//  netmax-desktop
//
//  Single source of truth for visual styling: semantic color tokens
//  (brand accent + the A–F grade ramp), spacing constants, and the
//  corner-radius set. Future UI passes should consume these instead of
//  hard-coding hex values or ad-hoc `.green`/`.orange` system colors.
//
//  CONTRAST POLICY — WCAG 2.1 AA (§1.4.3, ≥ 4.5:1 for normal text):
//  every foreground token is a provider-based dynamic `NSColor` with a
//  light and a dark variant. Each variant is measured against the
//  surfaces it can actually appear on in its scheme:
//    · light variant vs #FFFFFF (card bg) and #F4F5F7 (page bg)
//    · dark variant  vs #1E1E1E / #2C2C2E (system dark window/raised
//      surfaces) and #1F2635 (brand header, see netmax_gui.py)
//  Ratios below were computed with the WCAG relative-luminance formula.
//  Note the stock SwiftUI palette does NOT meet this bar — e.g. system
//  `.green` is ≈ 1.9:1 on white — which is why the grade ramp defines
//  its own calibrated pairs rather than aliasing system colors.
//

import SwiftUI

enum Theme {

    // MARK: - Accent

    /// Brand accent (purple, shared with the Tkinter GUI's ACCENT token).
    /// Light = the user's standard-palette purple #7C5A9B: 5.54:1 vs
    /// #FFFFFF, 5.08:1 vs #F4F5F7. Dark = lightened tint #BCA3DC (the raw
    /// purple sinks to ≈ 2:1 on dark surfaces): 7.47:1 vs #1E1E1E,
    /// 6.25:1 vs #2C2C2E, 6.99:1 vs #1F2635.
    static let accent = dynamicColor(light: 0x7C5A9B, dark: 0xBCA3DC)

    // MARK: - Grade ramp (bufferbloat / score letters, best → worst)

    /// Grade A (excellent). Green pair chosen dark enough for light mode:
    /// light #116B3D = 6.57:1 vs #FFFFFF, 6.04:1 vs #F4F5F7; dark
    /// #4CD787 = 9.03:1 vs #1E1E1E, 7.55:1 vs #2C2C2E.
    static let gradeA = dynamicColor(light: 0x116B3D, dark: 0x4CD787)

    /// Grade B (good). Teal keeps A/B distinguishable without relying on
    /// hue alone: light #0B6E62 = 6.14:1 / 5.64:1; dark #3FD9BC =
    /// 9.42:1 / 7.87:1 (same surfaces as above).
    static let gradeB = dynamicColor(light: 0x0B6E62, dark: 0x3FD9BC)

    /// Grade C (fair). Amber reads as "caution"; the light variant is a
    /// browned amber because yellow-on-white is unreadable: light
    /// #8A5A00 = 5.93:1 / 5.44:1; dark #FFD233 = 11.53:1 / 9.64:1.
    static let gradeC = dynamicColor(light: 0x8A5A00, dark: 0xFFD233)

    /// Grade D (poor). Orange pair: light #AD4300 = 5.87:1 / 5.39:1;
    /// dark #FF9430 = 7.57:1 / 6.33:1.
    static let gradeD = dynamicColor(light: 0xAD4300, dark: 0xFF9430)

    /// Grade E (bad). Magenta sits between D's orange and F's red so the
    /// bottom of the ramp stays ordered: light #A11553 = 7.64:1 / 7.02:1;
    /// dark #FF6FA5 = 6.41:1 / 5.36:1.
    static let gradeE = dynamicColor(light: 0xA11553, dark: 0xFF6FA5)

    /// Grade F (failing). Red pair: light #C01B2E = 6.11:1 / 5.61:1;
    /// dark #FF7061 = 6.15:1 / 5.14:1 (a softened red — pure #FF0000 is
    /// only ≈ 4:1 even on black and glows harshly next to dark UI).
    static let gradeF = dynamicColor(light: 0xC01B2E, dark: 0xFF7061)

    // MARK: - Surfaces & text (system pass-throughs)

    // Aliases over Apple's system colors, which already adapt to the
    // scheme. Centralizing them here means future restyling has one file
    // to touch and views stop spelling out raw NSColor names.

    /// Card / page background (currently used by Reports, MenuBar, ModeLab).
    static let surface = Color(nsColor: .textBackgroundColor)

    /// Raised controls inside a surface.
    static let raisedSurface = Color(nsColor: .controlBackgroundColor)

    /// Hairline borders (the `.strokeBorder` cards).
    static let separator = Color(nsColor: .separatorColor)

    /// Primary label text.
    static let primaryText = Color(nsColor: .labelColor)

    /// De-emphasized caption text.
    static let secondaryText = Color(nsColor: .secondaryLabelColor)

    // MARK: - Spacing

    /// 4-pt rhythm. Matches the gaps already hand-rolled across the views
    /// (VStack spacing 12, section padding 16…) so adopting tokens is a
    /// mechanical substitution, not a redesign.
    enum Spacing {
        /// Icon ↔ label, chip insets.
        static let xs: CGFloat = 4
        /// Closely related controls within one row.
        static let sm: CGFloat = 8
        /// Default stack gap between related rows.
        static let md: CGFloat = 12
        /// Card padding and section gaps.
        static let lg: CGFloat = 16
        /// Window margins, between-card breathing room.
        static let xl: CGFloat = 24
    }

    // MARK: - Corner radii

    /// Three-step radius scale, keyed by component role.
    enum Radius {
        /// Buttons, text fields, chips.
        static let control: CGFloat = 6
        /// Cards and bordered panels.
        static let card: CGFloat = 10
        /// Sheets and large containers (e.g. onboarding).
        static let sheet: CGFloat = 14
    }

    // MARK: - Helpers

    /// Builds an appearance-reactive color from two sRGB hex triples
    /// (`0xRRGGBB`). The dynamic provider is re-consulted whenever the
    /// effective appearance changes, so both variants stay on their
    /// verified background without asset catalogs.
    private static func dynamicColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            // AppKit has no `isDark`; resolve via best-match against the
            // two base appearances (vibrant variants resolve onto these).
            let isDark = appearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return srgb(isDark ? dark : light)
        })
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
