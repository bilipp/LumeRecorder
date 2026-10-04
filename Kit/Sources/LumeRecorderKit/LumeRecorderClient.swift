import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Async client for a LumeRecorder server.
///
/// Stateless and `Sendable`: create one per server (and per token) and share
/// it freely. The client never retries — in particular it never re-sends a
/// `POST` or `DELETE`; pass an `idempotencyKey` to `createRecording` and retry
/// yourself if you need at-least-once semantics. The token only ever travels
/// in the `Authorization` header, never in a URL.
public final class LumeRecorderClient: Sendable {
    /// Bonjour/DNS-SD service type the server advertises.
    public static let bonjourServiceType = "_lume-recorder._tcp"
    /// Port the server listens on by default.
    public static let defaultPort = 8090
    /// The API version this client implements.
    public static let supportedAPIVersion = LumeRecorderAPI.version

    public let baseURL: URL
    public let token: String?
    public let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// A copy of this client that authenticates with `token`.
    public func withToken(_ token: String?) -> LumeRecorderClient {
        LumeRecorderClient(baseURL: baseURL, token: token, session: session)
    }

    // MARK: - Unauthenticated

    /// `GET /api/v1/info`. Throws `.unsupportedAPIVersion` for a server that
    /// speaks a different API version.
    public func info() async throws -> ServerInfo {
        let info: ServerInfo = try await send("GET", "info")
        try Self.checkAPIVersion(info.apiVersion)
        return info
    }

    /// `POST /api/v1/pair`. Throws `.unauthorized` for a wrong or expired code
    /// and `.rateLimited` after too many failed attempts.
    public func pair(code: String, deviceName: String) async throws -> PairResponse {
        let body = try Self.encode(PairRequest(code: code, deviceName: deviceName))
        let response: PairResponse = try await send("POST", "pair", body: body)
        try Self.checkAPIVersion(response.server.apiVersion)
        return response
    }

    // MARK: - Recordings

    /// `GET /api/v1/recordings` — newest start first.
    public func recordings() async throws -> [Recording] {
        try await send("GET", "recordings")
    }

    /// `POST /api/v1/recordings`. Reusing an `idempotencyKey` returns the
    /// recording the first call created instead of a duplicate.
    public func createRecording(
        _ request: CreateRecordingRequest,
        idempotencyKey: String? = nil
    ) async throws -> Recording {
        var headers: [String: String] = [:]
        if let idempotencyKey {
            headers[LumeRecorderAPI.idempotencyKeyHeader] = idempotencyKey
        }
        return try await send("POST", "recordings", body: Self.encode(request), headers: headers)
    }

    /// `POST /api/v1/recordings/{id}/stop` — cancels a scheduled recording or
    /// gracefully ends a running one (which then becomes `completed`).
    public func stopRecording(id: UUID) async throws -> Recording {
        try await send("POST", "recordings/\(id.uuidString)/stop")
    }

    /// `DELETE /api/v1/recordings/{id}` — stops if needed, deletes the media.
    public func deleteRecording(id: UUID) async throws {
        try await sendWithoutContent("DELETE", "recordings/\(id.uuidString)")
    }

    /// `POST /api/v1/recordings/{id}/playback` — a short-lived signed HLS URL
    /// that works for in-progress recordings too. Hand `url` straight to the
    /// player; it needs no headers.
    public func playback(id: UUID) async throws -> PlaybackGrant {
        try await send("POST", "recordings/\(id.uuidString)/playback")
    }

    // MARK: - Server & devices

    /// `GET /api/v1/status`.
    public func status() async throws -> ServerStatus {
        try await send("GET", "status")
    }

    /// `GET /api/v1/devices`.
    public func devices() async throws -> [PairedDevice] {
        try await send("GET", "devices")
    }

    /// `DELETE /api/v1/devices/{id}` — revokes that device's token (may be this device).
    public func unpair(deviceID: UUID) async throws {
        try await sendWithoutContent("DELETE", "devices/\(deviceID.uuidString)")
    }

    // MARK: - Base URL normalization

    /// Turns what a user typed into a server base URL.
    ///
    /// Accepts `host`, `host:port`, `http://host:port/…` and `https://host/…`.
    /// A missing scheme becomes `http`; a missing port on `http` becomes
    /// `8090` (an explicit `https://` URL without a port keeps 443, for
    /// reverse proxies). Paths, queries, fragments and credentials are dropped.
    /// Returns `nil` for anything that isn't a plausible http(s) host.
    public static func normalizedBaseURL(from userInput: String) -> URL? {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let hasScheme = trimmed.range(of: "://") != nil
        let candidate = hasScheme ? trimmed : "http://" + trimmed
        guard let parsed = URLComponents(string: candidate),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty
        else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = parsed.port {
            guard (1 ... 65535).contains(port) else { return nil }
            components.port = port
        } else if scheme == "http" {
            components.port = defaultPort
        }
        return components.url
    }

    // MARK: - Transport

    private static func checkAPIVersion(_ version: Int) throws {
        guard version == supportedAPIVersion else {
            throw LumeRecorderError.unsupportedAPIVersion(version)
        }
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try LumeRecorderCoding.makeEncoder().encode(value)
        } catch {
            throw LumeRecorderError.invalidRequest("Couldn't encode the request: \(error)")
        }
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await perform(method, path, body: body, headers: headers)
        do {
            return try LumeRecorderCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw LumeRecorderError.decoding(String(describing: error))
        }
    }

    private func sendWithoutContent(_ method: String, _ path: String) async throws {
        _ = try await perform(method, path, body: nil, headers: [:])
    }

    private func perform(
        _ method: String,
        _ path: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/" + path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.lumeData(for: request)
        } catch let error as URLError {
            throw LumeRecorderError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LumeRecorderError.decoding("Not an HTTP response")
        }
        guard !(200 ..< 300).contains(http.statusCode) else { return data }
        throw Self.error(status: http.statusCode, body: data)
    }

    static func error(status: Int, body: Data) -> LumeRecorderError {
        let payload = try? LumeRecorderCoding.makeDecoder().decode(ErrorResponse.self, from: body)
        let code = payload?.error.code
        let message = payload?.error.message
        switch status {
        case 400: return .invalidRequest(message ?? "Invalid request.")
        case 401: return .unauthorized
        case 404: return .notFound
        case 409: return .conflict(code: code ?? "conflict", message: message ?? "Conflict.")
        case 429: return .rateLimited
        case 507: return .insufficientStorage
        default: return .server(status: status, code: code, message: message)
        }
    }
}

extension URLSession {
    /// `data(for:)` with a completion-handler fallback where the async API is
    /// missing (swift-corelibs-foundation on Linux).
    fileprivate func lumeData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
            try await withCheckedThrowingContinuation { continuation in
                let task = dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error as? URLError ?? URLError(.unknown))
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                task.resume()
            }
        #else
            try await data(for: request)
        #endif
    }
}
