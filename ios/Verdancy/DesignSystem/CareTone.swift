import SwiftUI

extension CareType {
    /// The tone a care task speaks in, wherever it appears — declared once, so the
    /// droplet badge on Today and the Water card in the plan can never drift into
    /// two different blues.
    ///
    /// Lives here rather than on `Theme.Tone` because `Theme` is also compiled into
    /// the widget extension, which has no model layer.
    var tone: Theme.Tone {
        switch self {
        case .water: return .water
        case .fertilize: return .leaf
        case .prune: return .ember
        }
    }
}
