import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Every failure `LumeRecorderClient` can throw.
public enum LumeRecorderError: Error, Sendable {
    /// 401 — missing/revoked token, or (from `pair`) a wrong or expired code.
    case unauthorized
    /// 404 — the recording or device no longer exists.
    case notFound
    /// 409 — e.g. `concurrency_limit` or `not_playable`.
    case conflict(code: String, message: String)
    /// 429 — too many failed pairing attempts; wait a minute.
    case rateLimited
    /// 507 — the server is below its free-disk threshold.
    case insufficientStorage
    /// 400 — the request failed validation; the associated value is the server's message.
    case invalidRequest(String)
    /// Any other non-2xx response.
    case server(status: Int, code: String?, message: String?)
    /// The request never got an HTTP response (offline, DNS, refused, timeout…).
    case transport(URLError)
    /// The response body didn't match the expected shape.
    case decoding(String)
    /// The server speaks an API version this Kit doesn't implement.
    case unsupportedAPIVersion(Int)
}

extension LumeRecorderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Not authorized. Pair this device with the recorder again."
        case .notFound:
            "The item no longer exists on the recorder."
        case let .conflict(_, message):
            message
        case .rateLimited:
            "Too many attempts. Try again in a minute."
        case .insufficientStorage:
            "The recorder is out of disk space."
        case let .invalidRequest(message):
            message
        case let .server(status, _, message):
            message ?? "The recorder returned an error (HTTP \(status))."
        case let .transport(error):
            "Couldn't reach the recorder: \(error.localizedDescription)"
        case .decoding:
            "The recorder sent an unexpected response."
        case let .unsupportedAPIVersion(version):
            "The recorder uses API version \(version), which this app doesn't support. Update the app or the server."
        }
    }
}

extension LumeRecorderError: Equatable {
    public static func == (lhs: LumeRecorderError, rhs: LumeRecorderError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized), (.notFound, .notFound),
             (.rateLimited, .rateLimited), (.insufficientStorage, .insufficientStorage):
            true
        case let (.conflict(a, b), .conflict(c, d)):
            a == c && b == d
        case let (.invalidRequest(a), .invalidRequest(b)):
            a == b
        case let (.server(a, b, c), .server(d, e, f)):
            a == d && b == e && c == f
        case let (.transport(a), .transport(b)):
            a.code == b.code
        case let (.decoding(a), .decoding(b)):
            a == b
        case let (.unsupportedAPIVersion(a), .unsupportedAPIVersion(b)):
            a == b
        default:
            false
        }
    }
}
