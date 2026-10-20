import Foundation

enum TapError: LocalizedError {
    case osStatus(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let what, let code): return "\(what) failed (OSStatus \(code))"
        case .message(let text): return text
        }
    }
}
