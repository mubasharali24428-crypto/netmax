import Foundation

/// Multi-language support for NetMax
class Localization {
    static let shared = Localization()
    
    private init() {}
    
    /// Current language
    var currentLanguage: String {
        get { UserDefaults.standard.string(forKey: "netmax.language") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "netmax.language") }
    }
    
    /// Supported languages
    let languages = ["en", "es", "fr", "de", "ja", "ko", "zh"]
    
    /// Localized string
    func localize(_ key: String) -> String {
        return NSLocalizedString(key, comment: "")
    }
}
