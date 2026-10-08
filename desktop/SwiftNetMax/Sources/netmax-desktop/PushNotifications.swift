import Foundation
import UserNotifications

/// Push notifications for NetMax
class PushNotifications {
    static let shared = PushNotifications()
    
    private init() {}
    
    /// Request notification permission
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("✅ Push notifications enabled")
            }
        }
    }
    
    /// Send notification
    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
