import Foundation
import Observation

/// Care streak (iOS-PRD §11): consecutive days the user kept all due tasks done.
///
/// The server owns the streak — `POST /checkin` computes it from its own UTC date
/// and is what grants streak trees — so `applyServer(_:)` is authoritative for the
/// day it lands. The local rules below stay as the offline fallback: they run only
/// on a day no check-in has answered on, so a failed call never blanks a streak the
/// server is still counting.
@MainActor
@Observable
final class StreakTracker {
    private let countKey = "verdancy.streak.count"
    private let dayKey = "verdancy.streak.lastDay"
    private let serverDayKey = "verdancy.streak.serverDay"

    private(set) var current: Int

    init() {
        current = UserDefaults.standard.integer(forKey: countKey)
    }

    /// Adopt the streak `POST /checkin` just returned. Stamps today so the local
    /// fallback stands down for the rest of the day.
    func applyServer(_ value: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        current = value
        UserDefaults.standard.set(today, forKey: serverDayKey)
        save(count: value, day: today)
    }

    /// True once a check-in has landed today — the local rules must not overwrite it.
    private var syncedWithServerToday: Bool {
        guard let day = UserDefaults.standard.object(forKey: serverDayKey) as? Date else { return false }
        return Calendar.current.isDateInToday(day)
    }

    /// Clear on sign-out — the streak belongs to the account, not the device.
    func reset() {
        current = 0
        save(count: 0, day: nil)
        UserDefaults.standard.removeObject(forKey: serverDayKey)
    }

    func refresh(allCaughtUp: Bool) {
        guard !syncedWithServerToday else { return } // the server is the authority today
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
