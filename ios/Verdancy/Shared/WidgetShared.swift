import Foundation

/// Data handoff to the home-screen widget via the App Group container. The widget
/// never networks or decodes the full garden — the app writes this small summary
/// on every garden change; the widget just renders it.
///
/// Compiled into BOTH the app and widget targets (see project.yml).
enum WidgetShared {
    /// Must match the App Group registered on the Apple Developer portal and in
    /// both targets' entitlements.
    static let appGroupId = "group.com.verdancy.app"
    private static let fileName = "widget-summary.json"

    struct Summary: Codable {
        struct Item: Codable {
            let plantName: String
            let task: String
            let systemImage: String
            let overdueDays: Int
        }

        /// Top few due tasks (display), plus the true total.
        let items: [Item]
        let dueCount: Int
        let plantCount: Int
        let streak: Int
        let generatedAt: Date
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(fileName)
    }

    static func write(_ summary: Summary) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> Summary? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
