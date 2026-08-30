@preconcurrency import AVFoundation
import Observation
import SwiftUI

/// Plant-relevant light levels, bucketed from an estimated lux reading. Thresholds
/// are approximate (a phone camera is not a lab lux meter) but tuned to the
/// placement decisions that matter for houseplants.
enum LightLevel: Int, CaseIterable {
    case unknown = -1
    case low = 0
    case medium = 1
    case brightIndirect = 2
    case direct = 3

    static func from(lux: Double) -> LightLevel {
        switch lux {
        case ..<250: return .low
        case ..<800: return .medium
        case ..<2500: return .brightIndirect
        default: return .direct
        }
    }

    var title: String {
        switch self {
        case .unknown: return "Measuring…"
        case .low: return "Low light"
        case .medium: return "Medium light"
        case .brightIndirect: return "Bright, indirect"
        case .direct: return "Direct sun"
        }
    }

    /// Compact label for the light-meter gauge (full titles are too wide side-by-side).
    var shortTitle: String {
        switch self {
        case .unknown: return "—"
        case .low: return "Low"
        case .medium: return "Medium"
        case .brightIndirect: return "Bright"
        case .direct: return "Direct"
        }
    }

    var advice: String {
        switch self {
        case .unknown: return "Point the camera at the spot where the plant lives."
        case .low:
            return "A dim spot. Only low-light plants (snake plant, ZZ, pothos) will be content here."
        case .medium:
            return "Enough for many easygoing houseplants, but not for sun-lovers."
        case .brightIndirect:
            return "The sweet spot for most houseplants: bright, but out of harsh direct rays."
        case .direct:
            return "Strong, direct light. Great for cacti and succulents; can scorch tender leaves."
        }
    }

    var tint: Color {
        switch self {
        case .unknown: return Theme.Color.textSecondary
        case .low: return Theme.Color.terracotta
        case .medium: return Theme.Color.warning
        case .brightIndirect: return Theme.Color.leaf
        case .direct: return Theme.Color.sun
        }
    }

    /// Parse the plant's free-text lighting need into a target level. `indirect` is
    /// checked before `direct` because "bright indirect" contains the substring.
    static func target(from needs: String) -> LightLevel? {
        let s = needs.lowercased()
        if s.contains("indirect") { return .brightIndirect }
        if s.contains("full sun") || s.contains("direct") { return .direct }
        if s.contains("bright") { return .brightIndirect }
        if s.contains("medium") || s.contains("moderate") { return .medium }
        if s.contains("low") || s.contains("shade") { return .low }
        return nil
    }
}

/// Estimates ambient light (lux) from the back camera's live auto-exposure. It
/// reads the device's current ISO, shutter, and (fixed) aperture, converts to an
/// exposure value, then to approximate lux — the same math a light-meter app uses.
@MainActor
@Observable
final class LightMeter {
    private(set) var lux: Double = 0
    private(set) var level: LightLevel = .unknown
    private(set) var denied = false

    let session = AVCaptureSession()
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "verdancy.lightmeter")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var smoothed: Double?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { denied = true; return }
        default:
            denied = true
            return
        }
        configureIfNeeded()
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop it was scheduled on, so the
            // main-actor isolation holds — assert it rather than hopping async.
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard device == nil else { return }
        guard
            let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera)
        else {
            denied = true
            return
        }
        device = camera
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
    }

    /// Read live exposure and convert to lux (EV100 → lux ≈ 2.5 · 2^EV100).
    private func sample() {
        guard let device else { return }
        let iso = Double(device.iso)
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        let aperture = Double(device.lensAperture)
        guard iso > 0, seconds > 0, aperture > 0 else { return }

        let ev100 = log2((aperture * aperture) / seconds) - log2(iso / 100)
        let reading = max(0, 2.5 * pow(2, ev100))

        // Exponential smoothing so the readout doesn't jitter.
        let value = smoothed.map { $0 * 0.8 + reading * 0.2 } ?? reading
        smoothed = value
        lux = value
        level = LightLevel.from(lux: value)
    }
}
