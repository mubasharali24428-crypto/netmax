import XCTest
import SwiftUI
@testable import netmax_desktop

final class ThemeTokenContrastTests: XCTestCase {
    
    // Calculates luminance according to WCAG 2.0
    func luminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        let r_sRGB = r <= 0.03928 ? r / 12.92 : pow((r + 0.055) / 1.055, 2.4)
        let g_sRGB = g <= 0.03928 ? g / 12.92 : pow((g + 0.055) / 1.055, 2.4)
        let b_sRGB = b <= 0.03928 ? b / 12.92 : pow((b + 0.055) / 1.055, 2.4)
        return 0.2126 * r_sRGB + 0.7152 * g_sRGB + 0.0722 * b_sRGB
    }
    
    // Calculates contrast ratio between two colors
    func contrastRatio(lum1: CGFloat, lum2: CGFloat) -> CGFloat {
        let l1 = max(lum1, lum2)
        let l2 = min(lum1, lum2)
        return (l1 + 0.05) / (l2 + 0.05)
    }
    
    func getComponents(hex: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return (r, g, b)
    }
    
    func checkContrast(fg: UInt32, bg: UInt32, required: CGFloat, label: String) {
        let fgComp = getComponents(hex: fg)
        let bgComp = getComponents(hex: bg)
        let fgLum = luminance(r: fgComp.r, g: fgComp.g, b: fgComp.b)
        let bgLum = luminance(r: bgComp.r, g: bgComp.g, b: bgComp.b)
        let ratio = contrastRatio(lum1: fgLum, lum2: bgLum)
        
        XCTAssertGreaterThanOrEqual(ratio, required, "\(label) failed contrast ratio: \(String(format: "%.2f", ratio)) < \(required)")
    }
    
    func testContrast() {
        // Light mode text
        checkContrast(fg: 0x1A1D24, bg: 0xF7F8FA, required: 4.5, label: "Light Primary Text on Canvas")
        checkContrast(fg: 0x4B5563, bg: 0xF7F8FA, required: 4.5, label: "Light Secondary Text on Canvas")
        checkContrast(fg: 0x1A1D24, bg: 0xFFFFFF, required: 4.5, label: "Light Primary Text on Surface")
        checkContrast(fg: 0x4B5563, bg: 0xFFFFFF, required: 4.5, label: "Light Secondary Text on Surface")
        
        // Dark mode text
        checkContrast(fg: 0xF3F4F6, bg: 0x101318, required: 4.5, label: "Dark Primary Text on Canvas")
        checkContrast(fg: 0xC1C7D0, bg: 0x101318, required: 4.5, label: "Dark Secondary Text on Canvas")
        checkContrast(fg: 0xF3F4F6, bg: 0x1A2028, required: 4.5, label: "Dark Primary Text on Surface")
        checkContrast(fg: 0xC1C7D0, bg: 0x1A2028, required: 4.5, label: "Dark Secondary Text on Surface")
        
        // Controls / Focus (>= 3:1)
        checkContrast(fg: 0x4338CA, bg: 0xF7F8FA, required: 3.0, label: "Light Focus on Canvas")
        checkContrast(fg: 0xC4B5FD, bg: 0x101318, required: 3.0, label: "Dark Focus on Canvas")
        
        checkContrast(fg: 0x4F46E5, bg: 0xF7F8FA, required: 3.0, label: "Light Accent on Canvas")
        checkContrast(fg: 0xA5B4FC, bg: 0x101318, required: 3.0, label: "Dark Accent on Canvas")
        
        // Semantic Roles text/icons (>= 4.5:1 recommended, at least >= 3.0 required)
        checkContrast(fg: 0x059669, bg: 0xF7F8FA, required: 3.0, label: "Light Success on Canvas")
        checkContrast(fg: 0x4ADE80, bg: 0x101318, required: 3.0, label: "Dark Success on Canvas")
        
        checkContrast(fg: 0xB45309, bg: 0xF7F8FA, required: 3.0, label: "Light Warning on Canvas")
        checkContrast(fg: 0xFBBF24, bg: 0x101318, required: 3.0, label: "Dark Warning on Canvas")
        
        checkContrast(fg: 0xDC2626, bg: 0xF7F8FA, required: 3.0, label: "Light Error on Canvas")
        checkContrast(fg: 0xF87171, bg: 0x101318, required: 3.0, label: "Dark Error on Canvas")
        
        checkContrast(fg: 0x2563EB, bg: 0xF7F8FA, required: 3.0, label: "Light Info on Canvas")
        checkContrast(fg: 0x60A5FA, bg: 0x101318, required: 3.0, label: "Dark Info on Canvas")
    }
}
