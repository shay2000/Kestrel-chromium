enum BrowserNavigationFailure: Equatable {
    case unavailable, timedOut, offline, secureConnection, contentProcessStopped

    static func chromium(code: Int) -> Self? {
        switch code {
        case -3: return nil // An intentional cancellation is not a page failure.
        case -7: return .timedOut
        case -106, -109, -118: return .offline
        case -107, -299 ... -200: return .secureConnection
        default: return .unavailable
        }
    }

    var message: String {
        switch self {
        case .unavailable: return "This page could not be loaded. Check the address or try again."
        case .timedOut: return "This page took too long to respond. Try again."
        case .offline: return "The connection was interrupted. Check your internet connection and try again."
        case .secureConnection: return "A secure connection could not be established."
        case .contentProcessStopped: return "The page stopped responding. Reload it to continue."
        }
    }
}
