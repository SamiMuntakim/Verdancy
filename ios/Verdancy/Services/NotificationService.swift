import Foundation
import UserNotifications

/// Local care reminders (iOS-PRD §3.1/§12). Scheduled from each plant's cadence +
/// last_done_at, rescheduled on care completion / launch, cleared on delete.
/// Notifications are entirely on-device (no push infrastructure).
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let enabledKey = "verdancy.reminders.enabled"

    var remindersEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { cancelAll() }
        }
    }

    /// Ask for permission (used right after the first plant is saved).
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Replace all pending reminders with a fresh schedule from the current garden.
    func reschedule(for plants: [Plant]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard remindersEnabled else { return }

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let now = Date()
        let cal = Calendar.current
        for plant in plants {
            for type in CareType.allCases {
                guard let due = plant.care.task(for: type).nextDue(now: now) else { continue }

                // Prefer 9am on the due day; if that's already past, fire in an hour.
                var comps = cal.dateComponents([.year, .month, .day], from: due)
                comps.hour = 9
                let nineAM = cal.date(from: comps) ?? due
                let fire = nineAM > now ? nineAM : now.addingTimeInterval(3600)

                let content = UNMutableNotificationContent()
                content.title = "\(plant.displayName) needs you"
                content.body = "Time to \(type.rawValue) \(plant.displayName)."
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(fire.timeIntervalSince(now), 60), repeats: false)
                let request = UNNotificationRequest(
                    identifier: "care-\(plant.plantId)-\(type.rawValue)",
                    content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
