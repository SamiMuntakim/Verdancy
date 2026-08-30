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
                    scaleCard
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
        .onChange(of: meter.level) { _, _ in Haptics.tap() }
    }

    // MARK: - Hero preview

    private var preview: some View {
        CameraPreview(session: meter.session)
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .overlay { reticle }
            .overlay(alignment: .top) { aimPill }
            .overlay(alignment: .bottom) { readoutBar }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    private var aimPill: some View {
        Text("Aim at the plant's spot")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.top, Theme.Space.m)
    }

    /// A framing reticle so it's clear the reading comes from the centre of frame.
    private var reticle: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.75), lineWidth: 2)
            .frame(width: 96, height: 96)
            .overlay(Circle().fill(.white).frame(width: 5, height: 5))
            .shadow(color: .black.opacity(0.25), radius: 4)
            .offset(y: -18)
    }

    /// The live reading, floating on a frosted bar along the bottom of the frame.
    private var readoutBar: some View {
        HStack(spacing: Theme.Space.m) {
            Circle()
                .fill(meter.level.tint)
                .frame(width: 12, height: 12)
                .shadow(color: meter.level.tint.opacity(0.6), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(meter.level.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if meter.level != .unknown {
                    Text("≈ \(Int(meter.lux).formatted()) lux")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: Rectangle())
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: meter.level)
    }

    // MARK: - Light-spectrum scale

    private var scaleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            spectrum
            HStack(spacing: 0) {
                ForEach(Self.scaleLevels, id: \.self) { level in
                    Text(level.shortTitle)
                        .font(.caption2.weight(meter.level == level ? .bold : .regular))
                        .foregroundStyle(
                            meter.level == level ? level.tint : Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider().overlay(Theme.Color.separator)
            Text(meter.level.advice)
                .font(.subheadline)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.l)
        .card()
    }

    /// The four light bands as a continuous gradient, with a thumb at the current
    /// reading and a marker at the plant's ideal band when one is known.
    private var spectrum: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.Color.terracotta, Theme.Color.warning,
                                Theme.Color.leaf, Theme.Color.sun,
                            ],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(height: 12)
                    .frame(maxHeight: .infinity)

                if let target = targetLevel {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .offset(x: Self.position(for: target, width: w) - 5, y: -2)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                if meter.level != .unknown {
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(meter.level.tint, lineWidth: 5))
                        .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                        .frame(maxHeight: .infinity)
                        .offset(x: Self.position(for: meter.level, width: w) - 11)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.8), value: meter.level)
                }
            }
        }
        .frame(height: 28)
    }

    private static let scaleLevels: [LightLevel] = [.low, .medium, .brightIndirect, .direct]

    /// Centre-of-band x for a level, mapped across the gauge width.
    private static func position(for level: LightLevel, width: CGFloat) -> CGFloat {
        let index = max(0, level.rawValue)
        return (CGFloat(index) + 0.5) / CGFloat(scaleLevels.count) * width
    }

    private var targetLevel: LightLevel? {
        guard let needs = plant?.lightingNeeds, !needs.isEmpty else { return nil }
        return LightLevel.target(from: needs)
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
        .padding(Theme.Space.l)
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
        guard meter.level != .unknown, let target = targetLevel else { return nil }

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
                icon: "exclamationmark.triangle.fill", tint: Theme.Color.warning)
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
