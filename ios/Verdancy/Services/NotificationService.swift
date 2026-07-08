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
    /// `streak` powers the evening streak-protection nudge (iOS-PRD §11).
    func reschedule(for plants: [Plant], streak: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard remindersEnabled else { return }

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let now = Date()
        let cal = Calendar.current
        scheduleStreakNudge(for: plants, streak: streak, now: now, cal: cal, center: center)
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

    /// One warm evening nudge when a real streak would otherwise break today —
    /// empowerment, not guilt (iOS-PRD §11 framing rule). Skipped for short streaks,
    /// skipped when nothing is due, skipped late at night.
    private func scheduleStreakNudge(
        for plants: [Plant], streak: Int, now: Date, cal: Calendar, center: UNUserNotificationCenter
    ) {
        guard streak >= 3 else { return }

        let hasDueTask = plants.contains { plant in
            CareType.allCases.contains { type in
                guard let due = plant.care.task(for: type).nextDue(now: now) else { return false }
                return due <= now
            }
        }
        guard hasDueTask else { return }

        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 19
        comps.minute = 30
        guard let fire = cal.date(from: comps), fire > now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your \(streak)-day streak is alive 🌱"
        content.body = "One quick check-in keeps it growing — a plant is still waiting today."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(fire.timeIntervalSince(now), 60), repeats: false)
        let request = UNNotificationRequest(
            identifier: "streak-nudge", content: content, trigger: trigger)
        center.add(request)
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
