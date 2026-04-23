import Foundation
import UserNotifications

/// Posts a local user notification when a coordinator run finishes.
/// Authorization is requested once on app launch; if the user denies, posts
/// become silent no-ops.
enum RunCompletionNotificationService {
    private static let categoryID = "run.completion"

    /// Call once at app launch to request notification permission.
    /// Safe to call multiple times — the system coalesces.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            default:
                break
            }
        }
    }

    /// Posts a run-completion notification. Silently drops if the user hasn't
    /// granted permission, or if the app is currently foregrounded (we still
    /// post — the system will show a banner anyway; callers that want to
    /// suppress while focused can check their own UI state first).
    static func postRunCompleted(
        goal: String,
        succeededCount: Int,
        totalCount: Int,
        overallCompleted: Bool
    ) {
        let content = UNMutableNotificationContent()
        content.title = overallCompleted ? "Task completed" : "Task finished with issues"
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalLine = trimmed.isEmpty ? "Run finished." : trimmed
        content.body = "\(goalLine)\n\(succeededCount)/\(totalCount) steps succeeded."
        content.sound = .default
        content.categoryIdentifier = categoryID

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
