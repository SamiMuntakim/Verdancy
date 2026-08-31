#if DEBUG
import UIKit

/// Marketing-capture support (DEBUG + mock mode only). The mock garden's plants
/// carry `image_ref`s that no S3 bucket will ever serve, so `CachedAsyncImage`
/// would render the leaf placeholder everywhere. Seeding those refs from bundled
/// photos makes every capture show a real plant.
///
/// Inert in release builds and whenever `AppConfig.useMockAuth` is false, so this
/// can never touch a real user's cache.
///
/// Caveat: the `Plant*` imagesets it reads live in the asset catalog, which is not
/// DEBUG-gated, so they do ship (~270 KB of JPEG). Delete them and this file if a
/// release build has to be lean — nothing else references them.
enum ScreenshotSupport {
    /// `image_ref` (from `Plant.samples`) → bundled photo asset.
    private static let photos: [String: String] = [
        "u/mock/p/p1/a.jpg": "PlantMonstera",
        "u/mock/p/p2/a.jpg": "PlantSnake",
        "u/mock/p/p6/a.jpg": "PlantPothos",
        "u/mock/p/p8/a.jpg": "PlantFern",
        "u/mock/p/p9/a.jpg": "PlantOrchid",
        "u/mock/p/p10/a.jpg": "PlantSucculent",
    ]

    static func seedImageCache() async {
        guard AppConfig.useMockAuth else { return }
        for (ref, asset) in photos {
            guard let image = UIImage(named: asset),
                  let data = image.jpegData(compressionQuality: 0.9) else { continue }
            await ImageCache.shared.store(data, imageRef: ref)
        }
    }
}
#endif
