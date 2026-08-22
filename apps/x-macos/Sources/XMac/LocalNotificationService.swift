import Foundation
@preconcurrency import UserNotifications

actor LocalNotificationService {
    private let center: UNUserNotificationCenter?

    init() {
        // Command-line smoke binaries do not have an application bundle.
        // UserNotifications raises an Objective-C exception when asked for the
        // current center in that environment, so keep notifications optional.
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorization() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func post(title: String, body: String, sessionId: String) async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = sessionId
        try? await center.add(UNNotificationRequest(
            identifier: "\(sessionId)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }
}
