import Foundation

/// ISO-8601 parsing for the backend's timestamp strings (e.g. `2026-06-16T20:11:03.184Z`).
enum ISO {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return withFractional.date(from: string) ?? plain.date(from: string)
    }

    static func string(_ date: Date = Date()) -> String {
        withFractional.string(from: date)
    }
}
