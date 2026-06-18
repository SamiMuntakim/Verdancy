import Foundation

/// Typed API errors mapped from HTTP status codes (iOS-PRD §4). The UI keys off
/// these — `.paywall` presents the paywall, `.rateLimited` shows a friendly note.
enum APIError: Error, Equatable {
    case unauthorized // 401 (after a refresh+retry still failed)
    case paywall // 402 — free allowance exhausted
    case forbidden // 403
    case notFound // 404
    case rateLimited // 429 — subscriber daily cap
    case badRequest(String?)
    case server(Int)
    case decoding
    case network(String)
    case notConfigured

    var userMessage: String {
        switch self {
        case .unauthorized: return "Please sign in again."
        case .paywall: return "Your free scan is used up — subscribe to keep going."
        case .forbidden: return "You don't have access to that."
        case .notFound: return "We couldn't find that."
        case .rateLimited: return "You've scanned a lot today — try again tomorrow."
        case .badRequest(let m): return m ?? "Something about that request wasn't right."
        case .server: return "Something went wrong on our end. Please try again."
        case .decoding: return "We got an unexpected response."
        case .network(let m): return m
        case .notConfigured: return "The app isn't fully configured yet."
        }
    }
}
