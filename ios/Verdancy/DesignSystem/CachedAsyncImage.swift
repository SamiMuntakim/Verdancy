import SwiftUI

/// Resolves a plant image from the on-disk cache (by `image_ref`), downloading from
/// its presigned URL only on a miss. Shows a calm leaf placeholder otherwise.
struct CachedAsyncImage: View {
    let imageRef: String?
    let downloadURL: String?

    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: imageRef ?? "") { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Theme.Color.separator
            Image(systemName: "leaf.fill")
                .font(.title)
                .foregroundStyle(Theme.Color.leaf.opacity(0.5))
        }
    }

    private func load() async {
        guard let imageRef else { return }
        if let data = await ImageCache.shared.data(imageRef: imageRef, downloadURL: downloadURL),
           let image = UIImage(data: data) {
            uiImage = image
        }
    }
}
