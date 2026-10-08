import SwiftUI

/// Custom themes for NetMax
class CustomThemes {
    static let shared = CustomThemes()
    
    private init() {}
    
    /// Custom theme colors
    var customColors: [String: Color] = [:]
    
    /// Add custom theme
    func addTheme(name: String, color: Color) {
        customColors[name] = color
    }
    
    /// Remove custom theme
    func removeTheme(name: String) {
        customColors.removeValue(forKey: name)
    }
}
