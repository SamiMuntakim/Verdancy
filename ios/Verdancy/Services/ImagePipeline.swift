import Foundation
import ImageIO
import UIKit

/// On-device downsample to ≤ ~1 MP before any upload or AI call (iOS-PRD §5),
/// via ImageIO so we never decode the full-resolution image into memory.
enum ImagePipeline {
    static func downsampledJPEG(from data: Data, maxPixels: Int = 1_000_000, quality: CGFloat = 0.8) -> Data? {
        let maxDimension = CGFloat(Int(Double(maxPixels).squareRoot())) // ~1000 px on the long edge
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumb).jpegData(compressionQuality: quality)
    }

    static func downsampledJPEG(from image: UIImage, maxPixels: Int = 1_000_000, quality: CGFloat = 0.8) -> Data? {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        return downsampledJPEG(from: data, maxPixels: maxPixels, quality: quality)
    }

    static func base64(from jpeg: Data) -> String { jpeg.base64EncodedString() }
}
