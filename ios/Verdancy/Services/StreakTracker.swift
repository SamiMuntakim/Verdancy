import Foundation
import Observation

/// Care streak (iOS-PRD §11): consecutive days the user kept all due tasks done.
/// Persisted locally; advanced when the garden is fully caught up, broken when a
/// day is missed with tasks still due.
@MainActor
@Observable
final class StreakTracker {
    private let countKey = "verdancy.streak.count"
    private let dayKey = "verdancy.streak.lastDay"

    private(set) var current: Int

    init() {
        current = UserDefaults.standard.integer(forKey: countKey)
    }

    func refresh(allCaughtUp: Bool) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return }
        let last = (UserDefaults.standard.object(forKey: dayKey) as? Date).map { cal.startOfDay(for: $0) }

        if allCaughtUp {
            if last == today { return } // already counted today
            current = (last == yesterday) ? current + 1 : 1
            save(count: current, day: today)
        } else if let last, last < yesterday {
            // A full day passed with tasks still due — streak broken.
            current = 0
            save(count: 0, day: nil)
        }
    }

    private func save(count: Int, day: Date?) {
        UserDefaults.standard.set(count, forKey: countKey)
        if let day {
            UserDefaults.standard.set(day, forKey: dayKey)
        } else {
            UserDefaults.standard.removeObject(forKey: dayKey)
        }
    }
}
