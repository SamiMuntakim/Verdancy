import Foundation
import CryptoKit

/// Aggressive on-disk image cache keyed by the stable `image_ref` (iOS-PRD §4).
/// Each image downloads roughly once via its presigned `GET` URL; the cache is the
/// offline source. Presigned URLs rotate — the cache key never does.
actor ImageCache {
    static let shared = ImageCache()

    private let dir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("plant-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func path(for imageRef: String) -> URL {
        let digest = SHA256.hash(data: Data(imageRef.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    /// Cached bytes if present, else download from `downloadURL`, cache, and return.
    func data(imageRef: String, downloadURL: String?) async -> Data? {
        let file = path(for: imageRef)
        if let cached = try? Data(contentsOf: file) { return cached }
        guard let downloadURL, let url = URL(string: downloadURL) else { return nil }
        guard
            let (data, resp) = try? await URLSession.shared.data(from: url),
            let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Cache bytes we already have locally (e.g. the photo we just uploaded), so the
    /// grid/detail render instantly without a download.
    func store(_ data: Data, imageRef: String) {
        try? data.write(to: path(for: imageRef), options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
