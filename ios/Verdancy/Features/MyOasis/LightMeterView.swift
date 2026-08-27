import AVFoundation
import SwiftUI
import UIKit

/// Light meter (premium): point the camera at a spot and get a plant-relevant
/// light reading, plus a verdict against a specific plant's needs when one is
/// passed in. Reads live camera exposure via `LightMeter`.
struct LightMeterView: View {
    /// When set, the reading is judged against this plant's `lightingNeeds`.
    let plant: Plant?

    @State private var meter = LightMeter()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                if meter.denied {
                    permissionState
                } else {
                    preview
                    readoutCard
                    if let verdict { verdictCard(verdict) }
                    disclaimer
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.Color.background)
        .navigationTitle("Light Meter")
        .navigationBarTitleDisplayMode(.inline)
        .task { await meter.start() }
        .onDisappear { meter.stop() }
    }

    private var preview: some View {
        CameraPreview(session: meter.session)
            .frame(height: 260)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text("Aim at the plant's spot")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(Theme.Space.s)
            }
    }

    private var readoutCard: some View {
        VStack(spacing: Theme.Space.s) {
            Text(meter.level.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(meter.level.tint)
            if meter.level != .unknown {
                Text("≈ \(Int(meter.lux).formatted()) lux")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Text(meter.level.advice)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func verdictCard(_ verdict: Verdict) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: verdict.icon)
                .font(.headline)
                .foregroundStyle(verdict.tint)
                .frame(width: 32, height: 32)
                .background(verdict.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verdict.title).font(.subheadline.weight(.semibold))
                Text(verdict.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var disclaimer: some View {
        Text("A camera-based estimate. Use it as a guide, not a lab reading.")
            .font(.caption2)
            .foregroundStyle(Theme.Color.textSecondary)
            .multilineTextAlignment(.center)
    }

    private var permissionState: some View {
        VStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: "camera.metering.spot", tint: Theme.Color.terracotta)
            Text("Camera access needed")
                .font(.title3.weight(.semibold))
            Text("The light meter reads the camera's exposure to estimate brightness.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.primary)
        }
        .padding(.vertical, Theme.Space.xxl)
    }

    // MARK: - Verdict

    private struct Verdict {
        let title: String
        let detail: String
        let icon: String
        let tint: Color
    }

    private var verdict: Verdict? {
        guard meter.level != .unknown,
            let needs = plant?.lightingNeeds, !needs.isEmpty,
            let target = LightLevel.target(from: needs)
        else { return nil }

        let name = plant?.displayName ?? "this plant"
        switch meter.level.rawValue - target.rawValue {
        case 0:
            return Verdict(
                title: "Great spot",
                detail: "This matches what \(name) wants (\(target.title.lowercased())).",
                icon: "checkmark.circle.fill", tint: Theme.Color.leaf)
        case ..<0:
            return Verdict(
                title: "A bit dark here",
                detail:
                    "\(name) prefers \(target.title.lowercased()). Try a spot closer to a window.",
                icon: "arrow.up.circle.fill", tint: Theme.Color.terracotta)
        default:
            return Verdict(
                title: "Brighter than needed",
                detail:
                    "\(name) prefers \(target.title.lowercased()); strong light here may scorch it. Shift it back a little.",
                icon: "exclamationmark.triangle.fill", tint: .orange)
        }
    }
}

/// SwiftUI wrapper around an `AVCaptureVideoPreviewLayer`.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
