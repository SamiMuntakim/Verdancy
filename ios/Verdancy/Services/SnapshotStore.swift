import Foundation

/// On-disk JSON snapshot of the last fetch (iOS-PRD §4) for instant cold-start +
/// offline viewing. Its own camelCase format — independent of the API decoder.
struct GardenSnapshot: Codable {
    let plants: [Plant]
    let trees: TreeStatus
}

enum SnapshotStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("garden-snapshot.json")
    }

    static func save(_ snapshot: GardenSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> GardenSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GardenSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
