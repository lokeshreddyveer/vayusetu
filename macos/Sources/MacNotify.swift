import Foundation
import UserNotifications

/// One place that posts a local notification. It asks for permission the first time one is needed (and never before), and does nothing if the
/// person has said no, so every alert in the app behaves the same instead of silently failing without permission.
enum AlertNotifier {
    static func post(id: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert]); status = await center.notificationSettings().authorizationStatus }
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body
            _ = try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
