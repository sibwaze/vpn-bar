import Foundation
@preconcurrency import UserNotifications
import os.log

/// Thin wrapper for VPN status notifications.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "Notifications")

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in
                guard settings.authorizationStatus == .notDetermined else { return }
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    self.logger.error("Notification auth failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendVPNNotification(isConnected: Bool, connectionName: String?) {
        guard SettingsManager.shared.showNotifications else { return }

        let content = UNMutableNotificationContent()
        if isConnected {
            content.title = NSLocalizedString("notifications.title.connected", comment: "")
            if let name = connectionName {
                content.body = String(format: NSLocalizedString("notifications.body.connectedTo", comment: ""), name)
            } else {
                content.body = NSLocalizedString("notifications.body.connected", comment: "")
            }
        } else {
            content.title = NSLocalizedString("notifications.title.disconnected", comment: "")
            if let name = connectionName {
                content.body = String(format: NSLocalizedString("notifications.body.disconnectedFrom", comment: ""), name)
            } else {
                content.body = NSLocalizedString("notifications.body.disconnected", comment: "")
            }
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "vpn-status-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
