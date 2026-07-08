import Foundation

/// First-party, on-device funnel analytics — no third-party SDK. Events append to
/// a size-capped local JSONL file so conversion funnels (onboarding → scan → save →
/// paywall → trial) are inspectable in debug builds and via device logs.
///
/// Privacy: never log identifiers, JWTs, images, or free-text user input — event
/// names and coarse enum-like properties only.
///
/// Server upload is deliberately not wired: it needs a backend events endpoint,
/// which requires explicit approval (backend CLAUDE.md). This file is the seam.
enum Analytics {
    struct Event: Codable {
        let name: String
        let props: [String: String]
        let at: String
        let session: String
    }

    /// Random per-launch id so funnels can be stitched within a session.
    private static let session = String(UUID().uuidString.prefix(8)).lowercased()

    private static let store = EventStore()

    static func log(_ name: String, _ props: [String: String] = [:]) {
        let event = Event(name: name, props: props, at: ISO.string(), session: session)
        #if DEBUG
        print("[analytics] \(name) \(props)")
        #endif
        Task.detached(priority: .utility) { await store.append(event) }
    }

    private actor EventStore {
        private let url: URL = {
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("funnel-events.jsonl")
        }()

        func append(_ event: Event) {
            guard let data = try? JSONEncoder().encode(event),
                  let line = String(data: data, encoding: .utf8) else { return }
            // Cap the log so it can't grow unbounded on-device.
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int, size > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            let entry = line + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(entry.utf8))
            } else {
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
