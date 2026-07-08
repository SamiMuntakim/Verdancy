import SwiftUI
import Observation

@MainActor
@Observable
final class SmartScanViewModel {
    enum Mode: String, CaseIterable, Identifiable {
        case identify = "Identify"
        case diagnose = "Diagnose"
        var id: String { rawValue }
    }

    enum Phase {
        case idle
        case working(UIImage)
        case identified(CareCard, jpeg: Data)
        case diagnosed(DiagnosisCard, jpeg: Data)
        case paywall
        case rateLimited
        case error(String)
    }

    var mode: Mode = .identify
    var phase: Phase = .idle

    private let api: APIClient

    init(api: APIClient) { self.api = api }

    func scan(image: UIImage) async {
        guard let jpeg = ImagePipeline.downsampledJPEG(from: image) else {
            phase = .error("We couldn't process that photo. Try another.")
            return
        }
        let base64 = ImagePipeline.base64(from: jpeg)
        phase = .working(image)
        do {
            switch mode {
            case .identify:
                let card = try await api.identify(imageBase64: base64)
                phase = .identified(card, jpeg: jpeg)
                Haptics.success()
            case .diagnose:
                let card = try await api.diagnose(imageBase64: base64)
                phase = .diagnosed(card, jpeg: jpeg)
                Haptics.success()
            }
        } catch APIError.paywall {
            phase = .paywall
        } catch APIError.rateLimited {
            phase = .rateLimited
        } catch {
            // Offline/mock mode: show sample results so the loop is demoable.
            if AppConfig.useMockAuth {
                switch mode {
                case .identify: phase = .identified(.sample, jpeg: jpeg)
                case .diagnose: phase = .diagnosed(.sample, jpeg: jpeg)
                }
            } else {
                phase = .error((error as? APIError)?.userMessage ?? "Something went wrong.")
            }
        }
    }

    func reset() { phase = .idle }
}
