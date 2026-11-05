import AppKit
import UserNotifications

/// MicFlow's notifications: a new version (with an Update now button that installs it in one click)
/// and new What's New posts (clicking one opens it).
@MainActor
final class MicFlowNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MicFlowNotifier()
    private static let updateCategory = "micflow-update"
    private static let updateAction = "micflow-update-now"
    private static let postCategory = "micflow-post"
    private static let seenPostsKey = "notifiedPostIDs"

    /// Set by the app.
    var update: () -> Void = {}
    var openPosts: () -> Void = {}

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        let updateNow = UNNotificationAction(identifier: Self.updateAction, title: "Update now", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.updateCategory, actions: [updateNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.postCategory, actions: [], intentIdentifiers: []),
        ])
    }

    func notifyUpdate(_ version: String) {
        post(id: "micflow-update-\(version)", title: "MicFlow \(version) is ready",
             body: "Click Update now. Your settings, shortcuts and key stay as they are.", category: Self.updateCategory)
    }

    /// Posts not seen before. The first time, the posts already there are only remembered.
    func notifyNewPosts(_ posts: [SiteContent.Post]) {
        let defaults = UserDefaults.standard
        let ids = Set(posts.map(\.id))
        guard let seen = defaults.stringArray(forKey: Self.seenPostsKey).map(Set.init) else {
            defaults.set(Array(ids), forKey: Self.seenPostsKey)
            return
        }
        for item in posts.filter({ !seen.contains($0.id) }).prefix(3) {
            post(id: "micflow-post-\(item.id)", title: "New in MicFlow: \(item.title)",
                 body: String(item.body.prefix(200)), category: Self.postCategory)
        }
        defaults.set(Array(seen.union(ids)), forKey: Self.seenPostsKey)
    }

    private func post(id: String, title: String, body: String, category: String) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        Task { @MainActor in
            if category == Self.updateCategory { self.update() }
            else if category == Self.postCategory, action == UNNotificationDefaultActionIdentifier { self.openPosts() }
            completionHandler()
        }
    }
}
