import SwiftUI
import PhotosUI

/// Growth timeline (iOS-PRD §3.3): photos from `GET /plants/{id}/photos`, add via
/// `POST /uploads` → S3 → `POST /plants/{id}/photos`.
struct GrowthTimelineView: View {
    @Environment(AppModel.self) private var app

    let plant: Plant
    @State private var photos: [PhotoEntry] = []
    @State private var loading = false
    @State private var uploading = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                addButtons
                if loading && photos.isEmpty {
                    ProgressView().tint(Theme.Color.leaf).padding()
                } else if photos.isEmpty {
                    emptyState
                } else {
                    ForEach(photos) { photoRow($0) }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.background)
        .navigationTitle("Growth Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in Task { await add(image: image) } }.ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await add(image: image)
                }
                photoItem = nil
            }
        }
        .overlay { if uploading { ProgressView().tint(Theme.Color.leaf) } }
    }

    private var addButtons: some View {
        HStack(spacing: Theme.Space.m) {
            Button { showCamera = true } label: {
                Label("Photo", systemImage: "camera.fill")
            }
            .buttonStyle(.primary)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Library", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .foregroundStyle(Theme.Color.leaf)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Theme.Color.leaf.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            }
        }
        .disabled(uploading)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: "photo.stack")
            VStack(spacing: Theme.Space.xs) {
                Text("No photos yet").font(.title3.weight(.semibold))
                Text("Add a photo to track how \(plant.displayName) grows over time.")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(.vertical, Theme.Space.xxl)
    }

    private func photoRow(_ photo: PhotoEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let urlString = photo.downloadUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.Color.separator
                }
                .frame(maxWidth: .infinity).frame(height: 220).clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            if let caption = photo.caption, !caption.isEmpty {
                Text(caption).font(.subheadline)
            }
            if let date = ISO.date(photo.takenAt) {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .card()
    }

    private func load() async {
        guard !AppConfig.useMockAuth else { return } // mock: no backend, start empty
        loading = true
        defer { loading = false }
        photos = (try? await app.api.photos(plantId: plant.plantId)) ?? []
    }

    private func add(image: UIImage) async {
        guard let jpeg = ImagePipeline.downsampledJPEG(from: image) else {
            error = "Couldn't process that photo."
            return
        }
        uploading = true
        defer { uploading = false }
        do {
            if AppConfig.useMockAuth {
                photos.insert(PhotoEntry(takenAt: ISO.string(), caption: nil, downloadUrl: nil), at: 0)
            } else {
                let ticket = try await app.api.createUpload(kind: "photo", plantId: plant.plantId)
                try await app.api.uploadImage(to: ticket.uploadUrl, jpeg: jpeg)
                try await app.api.addPhoto(plantId: plant.plantId, imageRef: ticket.imageRef, caption: nil)
                await load()
            }
            Haptics.success()
        } catch {
            self.error = (error as? APIError)?.userMessage ?? "Couldn't add the photo."
        }
    }
}
