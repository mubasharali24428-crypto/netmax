import SwiftUI

/// System theme sync for NetMax
class SystemTheme {
    static let shared = SystemTheme()
    
    private init() {}
    
    /// Sync with system dark mode
    func sync() {
        if #available(macOS 10.14, *) {
            if NSApp.effectiveAppearance.name == .darkAqua {
                UserDefaults.standard.set("dark", forKey: "netmax.theme")
            } else {
                UserDefaults.standard.set("light", forKey: "netmax.theme")
            }
        }
    }
}
