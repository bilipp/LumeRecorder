import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import LumeRecorderKit
import Testing

/// Captured request + canned response, keyed by a per-test host so suites can
/// run in parallel against one `URLProtocol` class.
final class StubRegistry: @unchecked Sendable {
    struct Captured: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data?
    }

    typealias Handler = @Sendable (Captured) -> (Int, Data)

    static let shared = StubRegistry()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var captured: [String: [Captured]] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    func handle(host: String, request: Captured) -> (Int, Data)? {
        lock.withLock {
            captured[host, default: []].append(request)
            return handlers[host]
        }.map { $0(request) }
    }

    func requests(host: String) -> [Captured] {
        lock.withLock { captured[host] ?? [] }
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            body = Self.read(stream)
        }
        let captured = StubRegistry.Captured(
            method: request.httpMethod ?? "GET",
            path: url.path,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        guard let (status, data) = StubRegistry.shared.handle(host: url.host ?? "", request: captured) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("LumeRecorderClient")
struct ClientTests {
    let host = "stub-\(UUID().uuidString.lowercased()).test"

    private func makeClient(token: String? = "secret-token", handler: @escaping StubRegistry.Handler) -> LumeRecorderClient {
        StubRegistry.shared.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LumeRecorderClient(
            baseURL: URL(string: "http://\(host):8090")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private static func json(_ value: some Encodable) -> Data {
        try! LumeRecorderCoding.makeEncoder().encode(value)
    }

    private static func errorBody(_ code: String, _ message: String) -> Data {
        json(ErrorResponse(code: code, message: message))
    }

    @Test func infoIsUnauthenticatedAndChecksAPIVersion() async throws {
        let info = ServerInfo(id: UUID(), name: "nas", version: "0.1.0", apiVersion: 1)
        let client = makeClient(token: nil) { _ in (200, Self.json(info)) }
        #expect(try await client.info() == info)
        let request = try #require(StubRegistry.shared.requests(host: host).first)
        #expect(request.path == "/api/v1/info")
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func futureAPIVersionIsRejected() async {
        let info = ServerInfo(id: UUID(), name: "nas", version: "9.0.0", apiVersion: 2)
        let client = makeClient { _ in (200, Self.json(info)) }
        await #expect(throws: LumeRecorderError.unsupportedAPIVersion(2)) { try await client.info() }
    }

    @Test func createSendsBearerTokenBodyAndIdempotencyKey() async throws {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let recording = Recording(id: UUID(), title: "Match", start: now, end: now.addingTimeInterval(60), status: .scheduled, createdAt: now)
        let client = makeClient { _ in (201, Self.json(recording)) }
        let request = CreateRecordingRequest(streamURL: URL(string: "http://p/live/u/p/1.ts")!, title: "Match", start: now, end: now.addingTimeInterval(60))
        #expect(try await client.createRecording(request, idempotencyKey: "key-1") == recording)

        let captured = try #require(StubRegistry.shared.requests(host: host).first)
        #expect(captured.method == "POST")
        #expect(captured.path == "/api/v1/recordings")
        #expect(captured.headers["Authorization"] == "Bearer secret-token")
        #expect(captured.headers["Idempotency-Key"] == "key-1")
        let sent = try LumeRecorderCoding.makeDecoder().decode(CreateRecordingRequest.self, from: #require(captured.body))
        #expect(sent.title == "Match")
        #expect(sent.streamURL == request.streamURL)
    }

    @Test func deleteAndUnpairAcceptNoContent() async throws {
        let client = makeClient { _ in (204, Data()) }
        let id = UUID()
        try await client.deleteRecording(id: id)
        try await client.unpair(deviceID: id)
        let paths = StubRegistry.shared.requests(host: host).map { "\($0.method) \($0.path)" }
        #expect(paths == ["DELETE /api/v1/recordings/\(id.uuidString)", "DELETE /api/v1/devices/\(id.uuidString)"])
    }

    @Test(arguments: [
        (400, "invalid_request", LumeRecorderError.invalidRequest("end must be after start")),
        (401, "unauthorized", .unauthorized),
        (401, "pairing_invalid", .unauthorized),
        (404, "not_found", .notFound),
        (409, "concurrency_limit", .conflict(code: "concurrency_limit", message: "end must be after start")),
        (429, "rate_limited", .rateLimited),
        (507, "insufficient_storage", .insufficientStorage),
        (500, "internal_error", .server(status: 500, code: "internal_error", message: "end must be after start")),
    ])
    func mapsHTTPErrors(status: Int, code: String, expected: LumeRecorderError) async {
        let client = makeClient { _ in (status, Self.errorBody(code, "end must be after start")) }
        await #expect(throws: expected) { _ = try await client.recordings() }
    }

    @Test func nonJSONErrorBodyStillMaps() async {
        let client = makeClient { _ in (502, Data("Bad Gateway".utf8)) }
        await #expect(throws: LumeRecorderError.server(status: 502, code: nil, message: nil)) { _ = try await client.status() }
    }

    @Test func failedPostIsNeverRetried() async {
        let client = makeClient { _ in (500, Self.errorBody("internal_error", "boom")) }
        let request = CreateRecordingRequest(streamURL: URL(string: "http://p/1.ts")!, title: "x", start: Date(), end: Date().addingTimeInterval(60))
        _ = try? await client.createRecording(request)
        #expect(StubRegistry.shared.requests(host: host).count == 1)
    }

    @Test func transportFailureIsWrapped() async {
        // No handler registered for this host → the stub fails the load.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = LumeRecorderClient(baseURL: URL(string: "http://unregistered.test:8090")!, session: URLSession(configuration: configuration))
        await #expect(throws: LumeRecorderError.transport(URLError(.cannotConnectToHost))) { _ = try await client.status() }
    }

    @Test func malformedSuccessBodyIsADecodingError() async {
        let client = makeClient { _ in (200, Data("{\"nope\":true}".utf8)) }
        do {
            _ = try await client.status()
            Issue.record("expected a decoding error")
        } catch let LumeRecorderError.decoding(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func errorsHaveShortDescriptions() {
        #expect(LumeRecorderError.rateLimited.localizedDescription == "Too many attempts. Try again in a minute.")
        #expect(LumeRecorderError.conflict(code: "x", message: "Too many recordings").localizedDescription == "Too many recordings")
    }
}
