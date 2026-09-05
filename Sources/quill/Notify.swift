import Foundation
@preconcurrency import UserNotifications

@MainActor
final class NativeNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NativeNotifications()

    enum NotificationError: Error, CustomStringConvertible {
        case appRequired, denied, deliveryUnconfirmed
        var description: String {
            switch self {
            case .appRequired: return "Run the installed Quill.app to use native notifications."
            case .denied: return "Enable Quill in System Settings > Notifications."
            case .deliveryUnconfirmed: return "Notification Center delivery could not be confirmed."
            }
        }
    }

    private func center() throws -> UNUserNotificationCenter {
        guard Bundle.main.bundleIdentifier == "com.bedeabza.quill",
              Bundle.main.bundleURL.pathExtension == "app" else { throw NotificationError.appRequired }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func authorize() async throws {
        let center = try center()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw NotificationError.denied
        }
    }

    func status() async throws -> [String: Any] {
        let settings = await (try center()).notificationSettings()
        let authorization: String
        switch settings.authorizationStatus {
        case .notDetermined: authorization = "not_determined"
        case .denied: authorization = "denied"
        case .authorized: authorization = "authorized"
        case .provisional: authorization = "provisional"
        @unknown default: authorization = "unknown"
        }
        return ["authorization": authorization,
                "alerts_enabled": settings.alertSetting == .enabled,
                "notification_center_enabled": settings.notificationCenterSetting == .enabled,
                "bundle_id": Bundle.main.bundleIdentifier ?? ""]
    }

    static func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title.hasPrefix("Quill: ") ? String(title.dropFirst(7)) : title
        content.body = body
        return content
    }

    func send(title: String, body: String) async throws -> String {
        try await authorize()
        let center = try center()
        let identifier = UUID().uuidString
        try await center.add(UNNotificationRequest(identifier: identifier, content: Self.content(title: title, body: body), trigger: nil))
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(300))
            let delivered = await center.deliveredNotifications()
            if delivered.contains(where: { $0.request.identifier == identifier }) { return identifier }
        }
        throw NotificationError.deliveryUnconfirmed
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

func notifyUser(title: String, body: String) {
    Task { @MainActor in
        do {
            let id = try await NativeNotifications.shared.send(title: title, body: body)
            FileHandle.standardError.write(Data("Quill notification delivered: \(id)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Quill notification failed: \(error)\n".utf8))
        }
    }
}
